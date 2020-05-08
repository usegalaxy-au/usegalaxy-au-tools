#! /bin/bash

AUTOMATED_TOOL_INSTALLATION_LOG="automated_tool_installation_log.tsv"; # version controlled
WORKING_INSTALLATION_LOG="${LOG_DIR}/installation_log.tsv";
LOG_HEADER="Category\tBuild Num.\tDate (AEST)\tName\tNew Tool\tStatus\tOwner\tInstalled Revision\tRequested Revision\tFailing Step\tStaging tests passed\tProduction tests passed\tSection Label\tTool Shed URL\tLog Path"

source ".env"
[ -f ".secret.env" ] && source ".secret.env"

install_tools() {
  echo "Running automated tool installation script"
  echo --------------------------
  echo "STAGING_URL = $STAGING_URL"
  echo "PRODUCTION_URL = $PRODUCTION_URL"
  echo "STAGING_TOOL_DIR = $STAGING_TOOL_DIR"
  echo "PRODUCTION_TOOL_DIR = $PRODUCTION_TOOL_DIR"

  # Jenkins build number
  echo "BUILD_NUMBER = $BUILD_NUMBER"
  echo "GIT_COMMIT = $GIT_COMMIT"
  echo "GIT_PREVIOUS_COMMIT = $GIT_PREVIOUS_COMMIT"
  echo -------------------------------

  if [ $MODE = "install" ] && [[ ! $REQUEST_FILES ]]; then
    echo "No files to install"
    exit 1
  fi

  # Ensure log file exists, create it if not
  if [ ! -f $AUTOMATED_TOOL_INSTALLATION_LOG ]; then
    echo -e $LOG_HEADER > $AUTOMATED_TOOL_INSTALLATION_LOG;
    git add $AUTOMATED_TOOL_INSTALLATION_LOG; # this has to be a tracked file
  fi

  # check out master, get out of detached head (skip if running locally)
  if [ $LOCAL_ENV = 0 ]; then
    git config --local user.name "galaxy-au-tools-jenkins-bot"
    git config --local user.email "galaxyaustraliatools@gmail.com"
    git checkout master
    git pull
  fi

  TMP="tmp/$MODE" # tmp/requests tmp/updates
  [ -d $TMP ] || mkdir -p $TMP;	# Important!  Make sure this exists

  # Concatenate logs from unsuccessfull installations/tests to ERROR_LOG
  # to use in a subsequent pull request
  ERROR_LOG="$TMP/error_log.txt"
  rm -f $ERROR_LOG ||:
  touch $ERROR_LOG

  TOOL_FILE_PATH="$TMP/$BUILD_NUMBER"
  mkdir -p $TOOL_FILE_PATH

  if [ "$MODE" = "install" ]; then
    # split requests into individual yaml files in tmp path
    # one file per unique revision so that installation can be run sequentially and
    # failure of one installation will not affect the others
    request_files_command="python scripts/organise_request_files.py -f $REQUEST_FILES -o $TOOL_FILE_PATH"
  elif [ "$MODE" = "update" ]; then
    request_files_command="python scripts/organise_request_files.py --update_existing -s $PRODUCTION_TOOL_DIR -o $TOOL_FILE_PATH -g $PRODUCTION_URL -a $PRODUCTION_API_KEY"
  fi
  {
    $request_files_command
  } || {
    echo "Error in organise_request_files.py"
    exit 1
  }

  # keep a count of successful installations
  NUM_TOOLS_TO_INSTALL=$(ls $TOOL_FILE_PATH | wc -l)
  INSTALLED_TOOL_COUNTER=0
  if [ $NUM_TOOLS_TO_INSTALL = 0 ]; then
    echo "Script error: nothing to install"
    exit 1
  fi

  for TOOL_FILE in $TOOL_FILE_PATH/*; do
    FILE_NAME=$(basename $TOOL_FILE)

    TOOL_REF=$(echo $FILE_NAME | cut -d'.' -f 1);
    TOOL_NAME=$(echo $TOOL_REF | cut -d '@' -f 1);
    REQUESTED_REVISION=$(echo $TOOL_REF | cut -d '@' -f 2); # TODO: Parsing from file name for revision and tool name is not good.  Fix.
    OWNER=$(grep -oE "owner: .*$" "$TOOL_FILE" | cut -d ':' -f 2 | xargs);
    TOOL_SHED_URL=$(grep -oE "tool_shed_url: .*$" "$TOOL_FILE" | cut -d ':' -f 2 | xargs);
    [ ! $TOOL_SHED_URL ] && TOOL_SHED_URL="toolshed.g2.bx.psu.edu"; # default value
    SECTION_LABEL=$(grep -oE "tool_panel_section_label: .*$" "$TOOL_FILE" | cut -d ':' -f 2 | xargs);

    # If either [FORCE] in the commit message or [SKIP_TESTS] in the file header, skip tests for this tool
    if [ "$(grep '\[SKIP_TESTS\]' $TOOL_FILE)" ] || [ $FORCE = 1 ]; then
      SKIP_TESTS=1
    else
      SKIP_TESTS=0
    fi

    # Find out whether tool/owner combination already exists on galaxy.  This makes no difference to the installation process but
    # is useful for the log
    TOOL_IS_NEW="False"
    if [ $MODE == "install" ]; then
      TOOL_IS_NEW=$(python scripts/is_tool_new.py -g $PRODUCTION_URL -a $PRODUCTION_API_KEY -n $TOOL_NAME -o $OWNER)
    fi

    unset STAGING_TESTS_PASSED PRODUCTION_TESTS_PASSED; # ensure these values do not carry over from previous iterations of the loop

    echo -e "\nInstalling $TOOL_NAME from file $TOOL_FILE"
    cat $TOOL_FILE

    {
      echo -e "\nStep (1): Installing $TOOL_NAME on staging server";
      install_tool "STAGING" $TOOL_FILE
    } && {
      echo -e "\nStep (2): Testing $TOOL_NAME on staging server";
      test_tool "STAGING" $TOOL_FILE
    } && {
      echo -e "\nStep (3): Installing $TOOL_NAME on production server";
      install_tool "PRODUCTION" $TOOL_FILE
    } && {
      echo -e "\nStep (4): Testing $TOOL_NAME on production server";
      test_tool "PRODUCTION" $TOOL_FILE
    }
  done

  git pull # update repo before changing tracked files

  echo -e "\n$INSTALLED_TOOL_COUNTER out of $NUM_TOOLS_TO_INSTALL tools installed."
  if [ ! -f $WORKING_INSTALLATION_LOG ]; then
    echo -e "\nWARNING: No log entry stored";
  else
    echo -e "\nWriting entry to $AUTOMATED_TOOL_INSTALLATION_LOG"
    echo "=================================================="
    echo -e $LOG_HEADER
    cat $WORKING_INSTALLATION_LOG
    echo "=================================================="
    cat $WORKING_INSTALLATION_LOG >> $AUTOMATED_TOOL_INSTALLATION_LOG;
  fi

  COMMIT_FILES=("$AUTOMATED_TOOL_INSTALLATION_LOG")

  # Update tool .yml files to reflect current state of galaxy tools
  update_tool_list "STAGING"
  update_tool_list "PRODUCTION"

  # Push changes to github
  # Add all existing .yml files to commit files list
  for FILE in $STAGING_TOOL_DIR/* $PRODUCTION_TOOL_DIR/*; do
    git add $FILE
    COMMIT_FILES+=("$FILE")
  done
  # Add any deleted .yml files to the commit files list as well
  for FILE in $(git diff --name-only --diff-filter=D $PRODUCTION_TOOL_DIR $STAGING_TOOL_DIR); do
    COMMIT_FILES+=("$FILE")
  done

  # Remove files from original pull request
  for FILE in $REQUEST_FILES; do
    git rm $FILE
    COMMIT_FILES+=("$FILE")
  done

  # log all git changes
  git diff | cat;
  git diff --staged | cat;

  echo -e "\nPushing Changes to github"
  COMMIT_MESSAGE="Jenkins $MODE build $BUILD_NUMBER."
  git commit "${COMMIT_FILES[@]}" -m "$COMMIT_MESSAGE"
  git push

  if [[ $(ls $TOOL_FILE_PATH ) ]]; then
    # Open up a new PR with any tool revisions that have failed installation
    COMMIT_PR_FILES=()
    echo "Opening new pull request for uninstalled tools:";
    echo "$(ls $TOOL_FILE_PATH )";
    BRANCH_NAME="jenkins/uninstalled_tools_${MODE}_${BUILD_NUMBER}"
    git checkout -b $BRANCH_NAME
    for TOOL_FILE in $TOOL_FILE_PATH/*; do
      PR_FILE="requests/$(basename $TOOL_FILE)"
      mv $TOOL_FILE $PR_FILE
      git add $PR_FILE
      COMMIT_PR_FILES+=("$PR_FILE")
    done
    git commit "${COMMIT_PR_FILES[@]}" -m "Jenkins $MODE build $BUILD_NUMBER errors"
    git push --set-upstream origin $BRANCH_NAME
    # Use 'hub' command to open pull request
    # hub takes a text file where a blank line separates the PR title from
    # the PR description.
    PR_FILE="$TMP/hub_pull_request_file"
    echo -e "Jenkins $MODE build $BUILD_NUMBER errors\n\n" > $PR_FILE
    cat $ERROR_LOG >> $PR_FILE
    hub pull-request -F $PR_FILE
    rm $PR_FILE
    git checkout master
  fi
  rm -r $TOOL_FILE_PATH

  echo -e "\nDone"
}

install_tool() {
  # Positional arguments: $1 = STAGING|PRODUCTION, $2 = tool file path
  TOOL_FILE="$2"
  SERVER="$1"
  set_url $SERVER
  STEP="$(title $SERVER) Installation"; # Production Installation or Staging Installation

  INSTALL_LOG="$TMP/install_log.txt"
  rm -f $INSTALL_LOG ||:;  # delete if it already exists

  # Ping galaxy url and toolshed url
  echo "Waiting for $URL";
  galaxy-wait -g $URL
  echo "Waiting for https://${TOOL_SHED_URL}";
  galaxy-wait -g "https://${TOOL_SHED_URL}"

  # Ephemeris install script
  command="shed-tools install -g $URL -a $API_KEY -t $TOOL_FILE -v --log_file $INSTALL_LOG"
  echo "${command/$API_KEY/<API_KEY>}"; # substitute API_KEY for printing
  {
    $command
  } || {
    log_row "Shed-tools error"; # well not really, more likely a connection error while running shed-tools
    log_error $LOG_FILE
    exit_installation 1
    return 1
  }

  # Capture the status (Installed/Skipped/Errored), name and revision hash from ephemeris output
  if [ $BASH_V = 4 ]; then
    PATTERN="(\w+) repositories \(1\): \[\('([^']+)',\s*u?'(\w+)'\)\]"
    [[ $(cat $INSTALL_LOG) =~ $PATTERN ]];
    INSTALLATION_STATUS="${BASH_REMATCH[1]}"
    INSTALLED_NAME="${BASH_REMATCH[2]}";
    INSTALLED_REVISION="${BASH_REMATCH[3]}";

    PATTERN="Repository ([^\s]+) is already installed"
    [[ $(cat $INSTALL_LOG) =~ $PATTERN ]];
    ALREADY_INSTALLED="${BASH_REMATCH[1]}";
    [ $ALREADY_INSTALLED ] && INSTALLATION_STATUS="Skipped";
  else # the regex above does not work on my local machine using bash 3 (Mac), hence this python workaround
    SHED_TOOLS_VALUES=($(python scripts/first_match_regex.py -p "(\w+) repositories \(1\): \[\('([^']+)',\s*u?'(\w+)'\)\]" $INSTALL_LOG));
    if [[ "${SHED_TOOLS_VALUES[*]}" ]]; then
      INSTALLATION_STATUS="${SHED_TOOLS_VALUES[0]}";
      INSTALLED_NAME="${SHED_TOOLS_VALUES[1]}";
      INSTALLED_REVISION="${SHED_TOOLS_VALUES[2]}";
    fi
    ALREADY_INSTALLED=$(python scripts/first_match_regex.py -p "Repository (\w+) is already installed" $INSTALL_LOG);
    [ $ALREADY_INSTALLED ] && INSTALLATION_STATUS="Skipped";
  fi

  if [ ! "$INSTALLATION_STATUS" ] || [ ! "$INSTALLED_NAME" ] || [ ! "$INSTALLED_REVISION" ]; then
    # TODO what if this is production server?  wind back staging installation?
    log_row "Script error"
    exit_installation 1 "Could not verify installation from shed-tools output."
    return 1
  fi
  if [ ! "$TOOL_NAME" = "$INSTALLED_NAME" ]; then
    # If these are not the same name it is probably due to this script.
    # uninstall and abandon process with 'Script error'
    python scripts/uninstall_tools.py -g $URL -a $API_KEY -n "$INSTALLED_NAME@$INSTALLED_REVISION";
    log_row "Script Error"
    exit_installation 1 "Unexpected value for name of installed tool.  Expecting $TOOL_NAME, received $INSTALLED_NAME";
    return 1
  fi

  # INSTALLATION_STATUS can have one of 3 values: Installed, Skipped, Errored
  if [ $INSTALLATION_STATUS = "Errored" ]; then
    # The tool may or may not be installed according to the API, so it needs to be
    # uninstalled with bioblend
    echo "Installation error.  Uninstalling $TOOL_NAME on $URL";
    python scripts/uninstall_tools.py -g $URL -a $API_KEY -n "$INSTALLED_NAME@$INSTALLED_REVISION";
    if [ $SERVER = "PRODUCTION" ]; then
      # also uninstall on staging
      echo "Uninstalling $TOOL_NAME on $STAGING_URL";
      python scripts/uninstall_tools.py -g $STAGING_URL -a $STAGING_API_KEY -n "$INSTALLED_NAME@$INSTALLED_REVISION";
    fi
    log_row $INSTALLATION_STATUS
    log_error $LOG_FILE
    exit_installation 1 ""
    return 1;

  elif [ $INSTALLATION_STATUS = "Skipped" ]; then
    # The linting process should prevent this scenario if the tool is installed on production
    # If the tool is installed on staging, skip testing
    # Only log the entry in 'install' mode, we expect to skip most tools when running in 'update' mode
    echo "Package appears to be already installed on $URL";
    if [ $SERVER = "PRODUCTION" ]; then
      if [ $MODE = "install" ]; then
        log_row "Already Installed"
        exit_installation 1 "Package is already installed"
      fi
      rm $TOOL_FILE;
      return 1
    fi
  elif [ $INSTALLATION_STATUS = "Installed" ]; then
    echo "$TOOL_NAME has been installed on $URL";
    if [ $SKIP_TESTS = 1 ] && [ $SERVER = "PRODUCTION" ]; then
      unset STEP
      log_row "Installed"
      exit_installation 0 ""
      rm $TOOL_FILE;
      return 0
    fi
  else
    log_row "Script error"
    exit_installation 1 "Could not verify installation from shed-tools output."
    return 1
  fi
}

test_tool() {
  # Positional arguments: $1 = STAGING|PRODUCTION, $2 = tool file path
  TOOL_FILE="$2"
  SERVER="$1"
  set_url $SERVER
  STEP="$(title $SERVER) Testing"; # Production Testing or Staging Testing
  TEST_JSON="${LOG_DIR}/$(lower $SERVER)/${TOOL_NAME}@${INSTALLED_REVISION}.json"
  PLANEMO_TEST_OUTPUT="${LOG_DIR}/planemo/${TOOL_NAME}@${INSTALLED_REVISION}_$(lower $SERVER).html"

  # Special case: If package is already installed on staging we skip tests and install on production
  if [ $SERVER = "STAGING" ] && [ $INSTALLATION_STATUS = "Skipped" ]; then
    echo "Skipping testing on $STAGING_URL";
    return 0;
  elif [ $SKIP_TESTS = 1 ]; then
    echo "FORCE or skip_tests option specified, skipping tests";
    return 0
  fi

  TEST_LOG="$TMP/test_log.txt"
  rm -f $TEST_LOG ||:;  # delete file if it exists

  sleep 120s; # Allow time for handlers to catch up

  # Ping galaxy url
  echo "Waiting for $URL";
  galaxy-wait -g $URL

  TOOL_PARAMS="--name $TOOL_NAME --owner $OWNER --revisions $INSTALLED_REVISION --toolshed $TOOL_SHED_URL"
  command="shed-tools test -g $URL -a $API_KEY $TOOL_PARAMS --parallel_tests 4 --test_json $TEST_JSON -v --log_file $TEST_LOG"
  echo "${command/$API_KEY/<API_KEY>}"
  {
    $command
  } || {
    log_row "Shed-tools error";
    log_error $LOG_FILE
    exit_installation 1
    return 1
  }

  if [ $BASH_V = 4 ]; then
    # normal regex
    PATTERN="Passed tool tests \(([0-9]+)\)"
    [[ $(cat $TEST_LOG) =~ $PATTERN ]];
    TESTS_PASSED="${BASH_REMATCH[1]}"
    PATTERN="Failed tool tests \(([0-9]+)\)"
    [[ $(cat $TEST_LOG) =~ $PATTERN ]];
    TESTS_FAILED="${BASH_REMATCH[1]}"
  else
    # resort to python helper
    TESTS_PASSED="$(python scripts/first_match_regex.py -p 'Passed tool tests \((\d+)\)' $TEST_LOG)"
    TESTS_FAILED="$(python scripts/first_match_regex.py -p 'Failed tool tests \((\d+)\)' $TEST_LOG)"
  fi

  # Proportion of tests passed for logs
  [ $SERVER = "STAGING" ] && STAGING_TESTS_PASSED="$TESTS_PASSED/$(($TESTS_PASSED+$TESTS_FAILED))";
  [ $SERVER = "PRODUCTION" ] && PRODUCTION_TESTS_PASSED="$TESTS_PASSED/$(($TESTS_PASSED+$TESTS_FAILED))";

  if [ $TESTS_FAILED = 0 ] && [ ! $TESTS_PASSED = 0 ]; then
    echo "All tests have passed for $TOOL_NAME at revision $INSTALLED_REVISION on $URL.";
    if [ "$SERVER" = "PRODUCTION" ]; then
      echo "Successfully installed $TOOL_NAME on $URL";
      unset STEP
      log_row "Installed"
      exit_installation 0 ""
      # remove installation file in requests/pending.  Any files that remain in this folder will
      # be added to a new PR opened by Jenkins
      rm $TOOL_FILE;
      return 0
    fi
  else
    STATUS="Tests failed"
    [ $TESTS_PASSED = 0 ] && [ $TESTS_FAILED = 0 ] && STATUS="No tests found"
    echo "Failed to install: $STATUS";
    # Uninstall tool if tests have failed.  If no tests are found, the tool may be a new revision
    # without a version bump, in which case it is not safe to uninstall it
    if [ "$STATUS" = "Tests failed" ]; then
      echo "Winding back installation: Uninstalling on $URL";
      python scripts/uninstall_tools.py -g $URL -a $API_KEY -n "$INSTALLED_NAME@$INSTALLED_REVISION";
      if [ $SERVER = "PRODUCTION" ]; then
        # also uninstall on staging
        echo "Uninstalling on $STAGING_URL";
        python scripts/uninstall_tools.py -g $STAGING_URL -a $STAGING_API_KEY -n "$INSTALLED_NAME@$INSTALLED_REVISION";
      fi
    fi
    log_row "$STATUS"
    log_error $TEST_JSON
    planemo test_reports $TEST_JSON --test_output $PLANEMO_TEST_OUTPUT
    exit_installation 1 ""
    return 1
  fi
}

log_row() {
  # LOG_HEADER="Category\tBuild Num.\tDate (AEST)\tName\tNew Tool\tStatus\tOwner\tInstalled Revision\tRequested Revision\tFailing Step\tStaging tests passed\tProduction tests passed\tSection Label\tTool Shed URL\tLog Path"
  STATUS="$1"
  DATE=$(env TZ="Australia/Queensland" date "+%d/%m/%y %H:%M:%S")
  LOG_ROW="$(title $MODE)\t$BUILD_NUMBER\t$DATE\t$TOOL_NAME\t$TOOL_IS_NEW\t$STATUS\t$OWNER\t$INSTALLED_REVISION\t$REQUESTED_REVISION\t$STEP\t$STAGING_TESTS_PASSED\t$PRODUCTION_TESTS_PASSED\t$SECTION_LABEL\t$TOOL_SHED_URL\t$LOG_FILE"
  echo -e $LOG_ROW >> $WORKING_INSTALLATION_LOG
}

log_error() {
  FILE=$(realpath "$1")
  echo -e "Failed to install $TOOL_NAME on $URL\nSee log on Jenkins: $FILE\n\n" >> $ERROR_LOG
}

exit_installation() {
  unset OUTCOME
  FAILED="$1"; # 0 for success, 1 for failure
  MESSAGE="$2";
  if [ "$FAILED" = "1" ]; then
    OUTCOME="Failed to install"
  elif [ "$FAILED" = "0" ]; then
    OUTCOME="Successfully installed"
    INSTALLED_TOOL_COUNTER=$((INSTALLED_TOOL_COUNTER+1))
  fi
  echo -e "\n$OUTCOME $TOOL_NAME." $MESSAGE
}

update_tool_list() {
  SERVER="$1" # This argument is required.  This script will exit if it is not either "STAGING" or "PRODUCTION"
  set_url $SERVER

  TMP_TOOL_FILE="$TMP/tool_list.yml"
  rm -f $TMP_TOOL_FILE ||:; # remove temp file if it exists
  [ -d $TOOL_DIR ] || mkdir $TOOL_DIR;  # make directory if it does not exist
  rm $TOOL_DIR/*; # Delete tool files to replace them with split_tool_yml output
  get-tool-list -g $URL -a $API_KEY -o $TMP_TOOL_FILE --get_data_managers --include_tool_panel_id
  python scripts/split_tool_yml.py -i $TMP_TOOL_FILE -o $TOOL_DIR; # Simon's script
  rm $TMP_TOOL_FILE
}

set_url() {
  # Set URL, API_KEY, variables that differ between staging and production
  SERVER="$1"
  if [ $SERVER = "STAGING" ]; then
    API_KEY=$STAGING_API_KEY
    URL=$STAGING_URL
    TOOL_DIR=$STAGING_TOOL_DIR
  elif [ $SERVER = "PRODUCTION" ]; then
    API_KEY=$PRODUCTION_API_KEY
    URL=$PRODUCTION_URL
    TOOL_DIR=$PRODUCTION_TOOL_DIR
  else
    echo "First positional argument to install_tool, test_tool or update_tool_list must be STAGING or PRODUCTION.  Exiting"
    exit 1
  fi
}

# Just use python to get titlecase and lowercase
title() {
  python -c "print('$1'.title())"
}

lower() {
  python -c "print('$1'.lower())"
}

install_tools
