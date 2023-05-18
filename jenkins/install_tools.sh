#! /bin/bash
source jenkins/utils.sh

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
    git config --local user.name $GITHUB_ACCOUNT_NAME
    git config --local user.email $GITHUB_ACCOUNT_EMAIL
    git checkout $GITHUB_BRANCH
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
    request_files_command="python scripts/organise_request_files.py -f $REQUEST_FILES -o $TOOL_FILE_PATH -g $PRODUCTION_URL -a $PRODUCTION_API_KEY"
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

    # Extract details (tool name, owner etc) from TOOL_FILE with some grepping and brute force
    TOOL_REF=$(echo $FILE_NAME | cut -d'.' -f 1);
    TOOL_NAME=$(echo $TOOL_REF | cut -d '@' -f 1);
    REQUESTED_REVISION=$(echo $TOOL_REF | cut -d '@' -f 2);
    OWNER=$(grep -oE "owner: .*$" "$TOOL_FILE" | cut -d ':' -f 2 | xargs);
    TOOL_SHED_URL=$(grep -oE "tool_shed_url: .*$" "$TOOL_FILE" | cut -d ':' -f 2 | xargs);
    [ ! $TOOL_SHED_URL ] && TOOL_SHED_URL="toolshed.g2.bx.psu.edu"; # default value
    SECTION_LABEL=$(grep -oE "tool_panel_section_label: .*$" "$TOOL_FILE" | cut -d ':' -f 2 | xargs);

    [ "$(grep '\[VERSION_UPDATE\]' $TOOL_FILE)" ] && VERSION_UPDATE=1 || VERSION_UPDATE=0; # VERSION_UPDATE means do not uninstall under any circumstances
    # If either [FORCE] in the commit message or [VERSION_UPDATE] in the file header, skip tests for this tool
    if [ $VERSION_UPDATE = 1 ] || [ $FORCE = 1 ]; then
      SKIP_TESTS=1
    else
      SKIP_TESTS=0
    fi

    # Find out whether tool/owner combination already exists on galaxy.  This makes no difference to the installation process but
    # is useful for the log
    TOOL_IS_NEW="False"
    if [ $MODE == "install" ]; then
      galaxy-wait -g $PRODUCTION_URL
      TOOL_IS_NEW=$(python scripts/is_tool_new.py -g $PRODUCTION_URL -a $PRODUCTION_API_KEY -n $TOOL_NAME -o $OWNER)
    fi

    unset STAGING_TESTS_PASSED PRODUCTION_TESTS_PASSED; # ensure these values do not carry over from previous iterations of the loop

    echo -e "\nInstalling $TOOL_NAME from file $TOOL_FILE"
    cat $TOOL_FILE

    {
      if [ $STAGING_URL ]; then
        echo -e "\nStep (1): Installing $TOOL_NAME on staging server";
        install_tool "STAGING"
      fi
    } && {
      if [ $STAGING_URL ]; then
        echo -e "\nStep (2): Testing $TOOL_NAME on staging server";
        test_tool "STAGING"
      fi
    } && {
      echo -e "\nStep (3): Installing $TOOL_NAME on production server";
      install_tool "PRODUCTION"
    } && {
      echo -e "\nStep (4): Testing $TOOL_NAME on production server";
      test_tool "PRODUCTION"
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
  # Positional argument: $1 = STAGING|PRODUCTION
  SERVER="$1"
  set_url $SERVER
  STEP="$(title $SERVER) Installation"; # Production Installation or Staging Installation

  INSTALL_LOG="$TMP/install_log.txt"
  rm -f $INSTALL_LOG ||:;  # delete if it already exists

  # Wait for galaxy and toolshed
  echo "Waiting for $URL";
  galaxy-wait -g $URL
  echo "Waiting for https://${TOOL_SHED_URL}";
  galaxy-wait -g "https://${TOOL_SHED_URL}"

  # Ephemeris install script
  command="shed-tools install -g $URL -a $API_KEY -t $TOOL_FILE -v --log_file $INSTALL_LOG --install_tool_dependencies"
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
  SHED_TOOLS_VALUES=($(python scripts/first_match_regex.py -p "(\w+) repositories \(1\): \[\('([^']+)',\s*u?'(\w+)'\)\]" $INSTALL_LOG));
  if [[ "${SHED_TOOLS_VALUES[*]}" ]]; then
    INSTALLATION_STATUS="${SHED_TOOLS_VALUES[0]}";
    INSTALLED_NAME="${SHED_TOOLS_VALUES[1]}";
    INSTALLED_REVISION="${SHED_TOOLS_VALUES[2]}";
  fi
  ALREADY_INSTALLED=$(python scripts/first_match_regex.py -p "Repository (\w+) is already installed" $INSTALL_LOG);
  [ $ALREADY_INSTALLED ] && INSTALLATION_STATUS="Skipped";
  # fi

  if [ ! "$INSTALLATION_STATUS" ] || [ ! "$INSTALLED_NAME" ] || [ ! "$INSTALLED_REVISION" ]; then
    log_row "Script error"
    exit_installation 1 "Could not verify installation from shed-tools output."
    return 1
  fi

  # INSTALLATION_STATUS can have one of 3 values: Installed, Skipped, Errored
  if [ $INSTALLATION_STATUS = "Errored" ]; then
    # The tool may or may not be installed according to the API, so it needs to be
    # uninstalled with bioblend
    echo "Winding back installation due to API error."
    uninstall_tool
    log_row $INSTALLATION_STATUS
    log_error $LOG_FILE
    exit_installation 1 ""
    return 1;

  elif [ $INSTALLATION_STATUS = "Skipped" ]; then
    # If the tool is installed on staging, skip testing
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
  # Positional argument: $1 = STAGING|PRODUCTION
  SERVER="$1"
  set_url $SERVER
  STEP="$(title $SERVER) Testing"; # Production Testing or Staging Testing
  TEST_JSON="${LOG_DIR}/$(lower $SERVER)/${TOOL_NAME}@${INSTALLED_REVISION}.json"
  PLANEMO_TEST_OUTPUT="${LOG_DIR}/planemo/${TOOL_NAME}@${INSTALLED_REVISION}_$(lower $SERVER).html"

  # If the tool was already installed or the SKIP_TESTS flag is set, skip tests
  if [ $SKIP_TESTS = 1 ] || [ $INSTALLATION_STATUS = "Skipped" ]; then
    echo "FORCE option specified or tool/version already installed. Skipping tests.";
    return 0
  fi

  TEST_LOG="$TMP/test_log.txt"
  rm -f $TEST_LOG ||:;  # delete file if it exists

  sleep 60s; # Allow time for handlers to catch up

  # Wait for galaxy
  echo "Waiting for $URL";
  galaxy-wait -g $URL

  TOOL_PARAMS="--name $TOOL_NAME --owner $OWNER --revisions $INSTALLED_REVISION --toolshed $TOOL_SHED_URL"
  command="shed-tools test -g $URL -a $API_KEY $TOOL_PARAMS --test_json $TEST_JSON -v --log_file $TEST_LOG"
  echo "${command/$API_KEY/<API_KEY>}"
  {
    $command
  } || {
    log_row "Shed-tools error";
    log_error $LOG_FILE
    exit_installation 1
    return 1
  }

  # use python regex helper to get test results from shed-tools log
  TESTS_PASSED="$(python scripts/first_match_regex.py -p 'Passed tool tests \((\d+)\)' $TEST_LOG)"
  TESTS_FAILED="$(python scripts/first_match_regex.py -p 'Failed tool tests \((\d+)\)' $TEST_LOG)"

  # Proportion of tests passed for logs
  [ $SERVER = "STAGING" ] && STAGING_TESTS_PASSED="$TESTS_PASSED/$(($TESTS_PASSED+$TESTS_FAILED))";
  [ $SERVER = "PRODUCTION" ] && PRODUCTION_TESTS_PASSED="$TESTS_PASSED/$(($TESTS_PASSED+$TESTS_FAILED))";

  if [ $TESTS_FAILED = 0 ]; then
    if [ $TESTS_PASSED = 0 ]; then
      echo "WARNING: There are no tests for $TOOL_NAME at revision $INSTALLED_REVISION.  Proceeding as none have failed.";
    fi
    if [ "$SERVER" = "PRODUCTION" ]; then
      echo "Successfully installed $TOOL_NAME on $URL";
      unset STEP
      log_row "Installed"
      exit_installation 0 ""
      # remove installation file from TOOL_FILE_PATH.  Any files that remain in this folder will
      # be added to a new PR opened by Jenkins
      rm $TOOL_FILE;
      return 0
    fi
  else
    echo "Winding back installation as some tests have failed"
    uninstall_tool
    log_row "Tests failed"
    log_error $TEST_JSON
    planemo test_reports $TEST_JSON --test_output $PLANEMO_TEST_OUTPUT
    exit_installation 1 ""
    return 1
  fi
}

uninstall_tool() {
  if [ $VERSION_UPDATE = 1 ]; then
    echo "This tool cannot be uninstalled as the version is already installed."
  else
    echo "Waiting for $URL"
    galaxy-wait -g $URL
    echo "Uninstalling on $URL"
    python scripts/uninstall_tools.py -g $URL -a $API_KEY -n "$INSTALLED_NAME@$INSTALLED_REVISION";
    if [ $SERVER = "PRODUCTION" ]; then
      # also uninstall on staging
      echo "Waiting for $STAGING_URL"
      galaxy-wait -g $STAGING_URL
      echo "Uninstalling on $STAGING_URL";
      python scripts/uninstall_tools.py -g $STAGING_URL -a $STAGING_API_KEY -n "$INSTALLED_NAME@$INSTALLED_REVISION";
    fi
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
  echo "Waiting for $URL";
  galaxy-wait -g $URL
  get-tool-list -g $URL -a $API_KEY -o $TMP_TOOL_FILE --get_all_tools
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

