#!/bin/bash

# Install all tools from galaxy production server to new server.  This is largely a copy of jenkins/install_tools, slightly simpler
# due to there only being one server.  The rules are different in that tools are only uninstalled for installation errors
# rather than test failures and nothing is being committed into the github repository.

if [ ! $URL ] || [ ! $API_KEY ] || [ ! $LOG_DIR ]; then
    echo "Expecting URL, API_KEY, LOG_DIR to be in context" # set these in Jenkins bash script
    exit 1;
fi

. ~/jobs_common/.venv3/bin/activate

# Log file of all installations
INSTALLATION_LOG=${LOG_DIR}/installation_log.tsv
LOG_HEADER="Build Num.\tDate (AEST)\tName\tStatus\tOwner\tInstalled Revision\tRequested Revision\tTests passed\Section Label\tTool Shed URL"

TEST_PLACEHOLDER="tests_pending"

log_row() {
  STATUS="$1"
  DATE=$(env TZ="Australia/Queensland" date "+%d/%m/%y %H:%M:%S")
  LOG_ROW="$BUILD_NUMBER\t$DATE\t$TOOL_NAME\t$STATUS\t$OWNER\t$INSTALLED_REVISION\t$REQUESTED_REVISION\t$TEST_PLACEHOLDER\t$SECTION_LABEL\t$TOOL_SHED_URL"
  echo -e $LOG_ROW >> $LOCAL_INSTALL_TSV
}

# Ensure log file exists, create it if not
[ ! -d $LOG_DIR ] && mkdir -p $LOG_DIR;
[ ! -f $AUTOMATED_TOOL_INSTALLATION_LOG ] && echo -e $LOG_HEADER > $AUTOMATED_TOOL_INSTALLATION_LOG;

INSTALL_FILE=$1
# This can be any yaml file, could be one per section.  This is probably the section name i.e. annotation.yml.
INSTALL_FILE_REF=$(echo $(basename $INSTALL_FILE) | cut -d'.' -f 1)

# store all single files in local directory to_install.  As tools are installed, remove these.
# This should allow for an easy recovery if the script stops anywhere
# keep a copy of any files with installation errors in ERROR_TOOL_PATH
FILES_DIR=${LOG_DIR}/build_${BUILD_NUMBER}/${INSTALL_FILE_REF}
TOOL_FILE_PATH=${FILES_DIR}/tool_files
ERROR_TOOL_PATH=${FILES_DIR}/error
mkdir -p $TOOL_FILE_PATH
mkdir -p $ERROR_TOOL_PATH

# keep all install info in FILES_DIR then add test results in test loop
LOCAL_INSTALL_TSV=${FILES_DIR}/install_log.tsv

python scripts/organise_request_files.py -f $INSTALL_FILE -o $TOOL_FILE_PATH

for TOOL_FILE in $TOOL_FILE_PATH/*; do
  FILE_NAME=$(basename $TOOL_FILE)

  TOOL_REF=$(echo $FILE_NAME | cut -d'.' -f 1);
  TOOL_NAME=$(echo $TOOL_REF | cut -d '@' -f 1);
  REQUESTED_REVISION=$(echo $TOOL_REF | cut -d '@' -f 2);
  OWNER=$(grep -oE "owner: .*$" "$TOOL_FILE" | cut -d ':' -f 2 | xargs);
  TOOL_SHED_URL=$(grep -oE "tool_shed_url: .*$" "$TOOL_FILE" | cut -d ':' -f 2 | xargs);
  [ ! $TOOL_SHED_URL ] && TOOL_SHED_URL="toolshed.g2.bx.psu.edu"; # default value
  SECTION_LABEL=$(grep -oE "tool_panel_section_label: .*$" "$TOOL_FILE" | cut -d ':' -f 2 | xargs);

  INSTALL_LOG=${FILES_DIR}/${TOOL_NAME}@${REQUESTED_REVISION}_install_log.txt

  # Ping galaxy url and toolshed url
  echo -e "\nWaiting for $URL";
  galaxy-wait -g $URL
  echo "Waiting for https://${TOOL_SHED_URL}";
  galaxy-wait -g "https://${TOOL_SHED_URL}"

  # Ephemeris install script
  command="shed-tools install -g $URL -a $API_KEY -t $TOOL_FILE -v --log_file $INSTALL_LOG"
  echo "${command/$API_KEY/<API_KEY>}"; # substitute API_KEY for printing
  $command

  # Capture the status (Installed/Skipped/Errored), name and revision hash from ephemeris output
  SHED_TOOLS_VALUES=($(python scripts/first_match_regex.py -p "(\w+) repositories \(1\): \[\('([^']+)',\s*u?'(\w+)'\)\]" $INSTALL_LOG));
  if [[ "${SHED_TOOLS_VALUES[*]}" ]]; then
    INSTALLATION_STATUS="${SHED_TOOLS_VALUES[0]}";
    INSTALLED_NAME="${SHED_TOOLS_VALUES[1]}";
    INSTALLED_REVISION="${SHED_TOOLS_VALUES[2]}";
  fi
  ALREADY_INSTALLED=$(python scripts/first_match_regex.py -p "Repository (\w+) is already installed" $INSTALL_LOG);
  [ $ALREADY_INSTALLED ] || [ "$INSTALLATION_STATUS" = "Skipped" ] && INSTALLATION_STATUS="Already Installed";

  # INSTALLATION_STATUS can have one of 3 values: Installed, Already Installed, Errored
  if [ ! "$INSTALLATION_STATUS" ] || [ "$INSTALLATION_STATUS" = "Errored" ]; then
    [ ! "$INSTALLATION_STATUS" ] && INSTALLATION_STATUS="Script Error"
    # The tool may or may not be installed according to the API, so it needs to be
    # uninstalled with bioblend
    echo "Winding back installation due to API error."
    python scripts/uninstall_tools.py -g $URL -a $API_KEY -n "$INSTALLED_NAME@$INSTALLED_REVISION";
    # In the case of installation errors there may be conda create process running that do not terminate
    # kill any conda create processes that are running. TODO: ensure that this file exists
    ssh jenkins_bot@$(basename $URL) "sudo bash /home/jenkins_bot/kill_conda_create.sh"
    log_row "$INSTALLATION_STATUS"
    mv $TOOL_FILE $ERROR_TOOL_PATH
  elif [ "$INSTALLATION_STATUS" = "Already Installed" ] || [ "$INSTALLATION_STATUS" = "Installed" ]; then
    # exit_installation 0 ""
    log_row "$INSTALLATION_STATUS"
    rm $TOOL_FILE;
  fi
done

sleep 60s
# run tests
cat $LOCAL_INSTALL_TSV | while read line || [[ -n $line ]]; do
  IFS=$'\t' read -ra words <<< "$line";
  TOOL_PARAMS="--name ${words[2]} --owner ${words[4]} --revisions ${words[6]} --toolshed ${words[9]}"

  TEST_LOG=${FILES_DIR}/${words[2]}@${words[5]}_test_log.txt
  TEST_JSON=${FILES_DIR}/${words[2]}@${words[5]}_test.json

  unset TESTS_PASSED; # ensure these values do not carry over from previous iterations of the loop

  # Ping galaxy url
  echo -e "\nWaiting for $URL";
  galaxy-wait -g $URL

  command="shed-tools test -g $URL -a $API_KEY $TOOL_PARAMS --parallel_tests 4 --test_json $TEST_JSON -v --log_file $TEST_LOG"
  echo "${command/$API_KEY/<API_KEY>}"
  {
    $command

    # use python regex helper to get test results from shed-tools log
    TESTS_PASSED="$(python scripts/first_match_regex.py -p 'Passed tool tests \((\d+)\)' $TEST_LOG)"
    TESTS_FAILED="$(python scripts/first_match_regex.py -p 'Failed tool tests \((\d+)\)' $TEST_LOG)"
    TESTS_PASSED="$TESTS_PASSED/$(($TESTS_PASSED+$TESTS_FAILED))";
    } || {
      TESTS_PASSED="Shed-tools error"
    }

    echo "${line/$TEST_PLACEHOLDER/$TESTS_PASSED}" >> $INSTALLATION_LOG
done

# consolidate all json and planemo test reports for this run
# store these at ground level in the log directory
AMALGAMATED_TOOL_TEST_JSON=${LOG_DIR}/build_${BUILD_NUMBER}_${INSTALL_FILE_REF}_tool_test.json
AMALGAMATED_TOOL_TEST_HTML=${LOG_DIR}/build_${BUILD_NUMBER}_${INSTALL_FILE_REF}_tool_test.html

planemo merge_test_reports $(find ${FILES_DIR} -name '*test.json') ${AMALGAMATED_TOOL_TEST_JSON}
planemo test_reports ${AMALGAMATED_TOOL_TEST_JSON}  --test_output ${AMALGAMATED_TOOL_TEST_HTML}
