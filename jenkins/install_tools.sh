#! /bin/bash

AUTOMATED_TOOL_INSTALLATION_LOG="automated_tool_installation_log.tsv"; # version controlled
LOG_HEADER="Category\tJenkins Build Number\tDate (UTC)\tStatus\tFailing Step\tStaging tests passed\tProduction tests passed\tName\tOwner\tRequested Revision\tInstalled Revision\tSection Label\tTool Shed URL\tLog Path"

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

  # activate .venv with yaml, bioblend, ephemeris installed
  activate_virtualenv

  # Ensure log file exists, create it if not
  if [ ! -f $AUTOMATED_TOOL_INSTALLATION_LOG ]; then
    echo -e $LOG_HEADER > $AUTOMATED_TOOL_INSTALLATION_LOG;
    git add $AUTOMATED_TOOL_INSTALLATION_LOG; # this has to be a tracked file
  fi

  # check out master, get out of detached head
  git checkout master
  git pull

  TMP="tmp/$(lower $MODE)s" # tmp/requests tmp/updates
  [ -d $TMP ] || mkdir -p $TMP;	# Important!  Make sure this exists

  # Concatenate logs from unsuccessfull installations/tests to ERROR_LOG
  # to use in a subsequent pull request
  ERROR_LOG="$TMP/error_log.txt"
  rm -f $ERROR_LOG ||:
  touch $ERROR_LOG

  TOOL_FILE_PATH="$TMP/pending/$BUILD_NUMBER"
  mkdir -p $TOOL_FILE_PATH

  if [ "$MODE" = "REQUEST" ]; then
    # split requests into individual yaml files in requests/pending
    # one file per unique revision so that installation can be run sequentially and
    # failure of one installation will not affect the others
    python scripts/organise_request_files.py -f $REQUEST_FILES -o $TOOL_FILE_PATH
  elif [ "$MODE" = "UPDATE" ]; then
    python scripts/organise_request_files.py --update_existing -s $PRODUCTION_TOOL_DIR -o $TOOL_FILE_PATH
  fi

  # keep a count of successful installations
  NUM_TOOLS_TO_INSTALL=$(ls $TOOL_FILE_PATH | wc -l)
  INSTALLED_TOOL_COUNTER=0

  # for FILE_NAME in $TOOL_FILE_PATH/*; do
  #   TOOL_FILE=$TOOL_FILE_PATH$FILE_NAME;
  for TOOL_FILE in $TOOL_FILE_PATH/*; do
    FILE_NAME=$(basename $TOOL_FILE)

    TOOL_REF=$(echo $FILE_NAME | cut -d'.' -f 1);
    TOOL_NAME=$(echo $TOOL_REF | cut -d '@' -f 1);
    REQUESTED_REVISION=$(echo $TOOL_REF | cut -d '@' -f 2); # TODO: Parsing from file name for revision and tool name is not good.  Fix.
    OWNER=$(grep -oE "owner: .*$" "$TOOL_FILE" | cut -d ':' -f 2);
    TOOL_SHED_URL=$(grep -oE "tool_shed_url: .*$" "$TOOL_FILE" | cut -d ':' -f 2);
    SECTION_LABEL=$(grep -oE "tool_panel_section_label: .*$" "$TOOL_FILE" | cut -d ':' -f 2);

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
  echo G

  echo -e "\n$INSTALLED_TOOL_COUNTER out of $NUM_TOOLS_TO_INSTALL tools installed."
  if [ ! "$LOG_ENTRY" ]; then
    echo -e "\nWARNING: No log entry stored";
  else
    echo -e "\nWriting entry to $AUTOMATED_TOOL_INSTALLATION_LOG"
    echo "=================================================="
    echo -e $LOG_HEADER
    echo -e $LOG_ENTRY
    echo "=================================================="
    echo -e $LOG_ENTRY >> $AUTOMATED_TOOL_INSTALLATION_LOG;
  fi

  COMMIT_FILES=("$AUTOMATED_TOOL_INSTALLATION_LOG")

  update_tool_list "STAGING"
  update_tool_list "PRODUCTION"

  # Push changes to github
  for YML_FILE in $STAGING_TOOL_DIR/*; do
    git add $YML_FILE
    COMMIT_FILES+=("$YML_FILE")
  done
  for YML_FILE in $PRODUCTION_TOOL_DIR/*; do
    git add $YML_FILE
    COMMIT_FILES+=("$YML_FILE")
  done

  # Remove files from original pull request

  # for FILE in $REQUESTS_DIFF
  for FILE in $REQUEST_FILES; do
    git rm $FILE
    COMMIT_FILES+=("$FILE")
  done

  # log all git changes
  git diff | cat;
  git diff --staged | cat;

  echo -e "\nPushing Changes to github"
  COMMIT_MESSAGE="Jenkins build $BUILD_NUMBER."
  git commit "${COMMIT_FILES[@]}" -m "$COMMIT_MESSAGE"
  git pull
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
    git commit "${COMMIT_PR_FILES[@]}" -m "Jenkins build $BUILD_NUMBER errors"
    git push --set-upstream origin $BRANCH_NAME
    # Use 'hub' command to open pull request
    # hub takes a text file where a blank line separates the PR title from
    # the PR description.
    PR_FILE="$TMP/hub_pull_request_file"
    echo -e "Jenkins build $BUILD_NUMBER errors\n\n" > $PR_FILE
    cat $ERROR_LOG >> $PR_FILE
    hub pull-request -F $PR_FILE
    rm $PR_FILE
    git checkout master
  fi
  rm -r $TOOL_FILE_PATH

  echo -e "\nDone"
}

activate_virtualenv() {
  # Virtual environment in build directory has ephemeris and bioblend installed.
  # If this script is being run for the first time on the jenkins server we
  # will need to set up the virtual environment
  if [ $LOCAL_ENV = 0 ]; then
    if [ ! -d "../.venv" ]; then
      echo "creating virtual environment";
            virtualenv $VIRTUALENV;
      cd ..
      pip install pyyaml
      pip install ephemeris
      pip install bioblend
      cd workspace || exit 1
    fi
    . ../.venv/bin/activate
  fi
}

install_tool() {
  # Positional arguments: $1 = STAGING|PRODUCTION, $2 = tool file path
  TOOL_FILE="$2"
  SERVER="$1"
  set_url $SERVER
  STEP="$(title $SERVER) Installation"; # Production Installation or Staging Installation

  INSTALL_LOG="$TMP/install_log.txt"
  rm -f $INSTALL_LOG ||:;  # delete if it already exists

  # Ephemeris install script
  command="shed-tools install -g $URL -a $API_KEY -t $TOOL_FILE -v --log_file $INSTALL_LOG"
  echo "${command/$API_KEY/<API_KEY>}"; # substitute API_KEY for printing
  {
    $command
  } || {
    log_row "Shed-tools error"; # well not really, more likely a connection error while running shed-tools
    log_error $INSTALL_LOG 250
    exit_installation 1
    echo "GETTING OUT OF HERE ABOUT TO RETURN 1 BAD SHED TOOOLS INSTALLATION"
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
    python scripts/uninstall_tools.py -g $URL -a $API_KEY -n $INSTALLED_NAME;
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
      python scripts/uninstall_tools.py -g $STAGING_URL -a $STAGING_API_KEY -n $INSTALLED_NAME;
    fi
    log_row $INSTALLATION_STATUS
    log_error $INSTALL_LOG
    exit_installation 1 ""
    return 1;

  elif [ $INSTALLATION_STATUS = "Skipped" ]; then
    # The linting process should prevent this scenario if the tool is installed on production
    # If the tool is installed on staging, skip testing
    # Only log the entry in REQUEST mode, we expect to skip most tools in UPDATE mode
    echo "Package appears to be already installed on $URL";
    if [ $SERVER = "PRODUCTION" ]; then
      if [ $MODE = "REQUEST" ]; then
        log_row "Already Installed"
        exit_installation 1 "Package is already installed"
      fi
      rm $TOOL_FILE;
      return 1
    fi
  elif [ $INSTALLATION_STATUS = "Installed" ]; then
    echo "$TOOL_NAME has been installed on $URL";

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
  TEST_JSON="$LOG_DIR/$BUILD_NUMBER"_"$(lower $SERVER)"_test.json

  # Special case: If package is already installed on staging we skip tests and install on production
  if [ $SERVER = "STAGING" ] && [ $INSTALLATION_STATUS = "Skipped" ]; then
    echo "Skipping testing on $STAGING_URL";
    return 0;
  fi

  TEST_LOG="$TMP/test_log.txt"
  rm -f $TEST_LOG ||:;  # delete if it does not exist

  command="shed-tools test -g $URL -a $API_KEY -t $TOOL_FILE --parallel_tests 4 --test_json $TEST_JSON -v --log_file $TEST_LOG"
  echo "${command/$API_KEY/<API_KEY>}"
  {
    $command
  } || {
    log_row "Shed-tools error"; # well not really, more likely a connection error while running shed-tools
    log_error $TEST_LOG 250
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

  if [ $TESTS_FAILED = 0 ]; then
    if [ $TESTS_PASSED = 0 ]; then
      echo "WARNING: There are no tests for $TOOL_NAME at revision $INSTALLED_REVISION.  Proceeding as none have failed.";
    else
      echo "All tests have passed for $TOOL_NAME at revision $INSTALLED_REVISION on $URL.";
    fi
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
    echo "Failed to install: Winding back installation as some tests have failed.";
    echo "Uninstalling on $URL";
    python scripts/uninstall_tools.py -g $URL -a $API_KEY -n $INSTALLED_NAME;
    if [ $SERVER = "PRODUCTION" ]; then
      # also uninstall on staging
      echo "Uninstalling on $STAGING_URL";
      python scripts/uninstall_tools.py -g $STAGING_URL -a $STAGING_API_KEY -n $INSTALLED_NAME;
    fi
    log_row "Tests failed"
    log_error $TEST_LOG
    exit_installation 1 ""
    return 1
  fi
}

log_row() {
  # "Category\tJenkins Build Number\tDate (UTC)\tStatus\tFailing Step\tStaging tests passed\tProduction tests passed\tName\tOwner\tRequested Revision\tInstalled Revision\tSection Label\tTool Shed URL\tLog Path"
  STATUS="$1"
  if [ "$LOG_ENTRY" ]; then
    LOG_ENTRY="$LOG_ENTRY\n";	# If log entry has content, add new line before new content
  fi
  LOG_ROW="$MODE\t$BUILD_NUMBER\t$(date)\t$STATUS\t$STEP\t$STAGING_TESTS_PASSED\t$PRODUCTION_TESTS_PASSED\t$TOOL_NAME\t$OWNER\t$REQUESTED_REVISION\t$INSTALLED_REVISION\t$SECTION_LABEL\t$TOOL_SHED_URL\t$LOG_FILE"
  LOG_ENTRY="$LOG_ENTRY$LOG_ROW"
  # echo -e $LOG_ROW; # Need to print this values?  Store them in multiD array? What if script stops in the middle?
}

log_error() {
  LOG_FILE="$1"
  LIMIT="$2"
  echo -e "Failed to install $TOOL_NAME on $URL\n" >> $ERROR_LOG
  [ ! $LIMIT ] && cat $LOG_FILE >> $ERROR_LOG || head -n $LIMIT $LOG_FILE >> $ERROR_LOG
  echo -e "\n\n" >> $ERROR_LOG;
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
  [ -d $TOOL_DIR ] || mkdir $TOOL_DIR  # make directory if it does not exist
  get-tool-list -g $URL -a $API_KEY -o $TMP_TOOL_FILE --get_data_managers
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
