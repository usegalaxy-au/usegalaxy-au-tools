#!/bin/bash

. ~/jobs_common/.venv3/bin/activate

TOOL_FILE=$1
SECTION=$(echo $(basename $TOOL_FILE) | cut -d'.' -f 1)

if [ ! $URL ] || [ ! $API_KEY ] || [ ! $LOG_DIR ]; then
    echo "Expecting URL, API_KEY, LOG_DIR to be in context" # set these in Jenkins bash script
    exit 1;
fi

INSTALL_LOG=${LOG_DIR}/${SECTION}_install_log.txt
TEST_LOG=${LOG_DIR}/${SECTION}_test_log.txt
TEST_JSON=${LOG_DIR}/${SECTION}_test.json
TEST_HTML=${LOG_DIR}/${SECTION}_test.html

shed-tools install -g ${URL} -a ${API_KEY} -t ${TOOL_FILE} -v --log_file ${INSTALL_LOG}
shed-tools test -g ${URL} -a ${API_KEY} -t ${TOOL_FILE} --parallel_tests 4 --test_json ${TEST_JSON} -v --log_file ${TEST_LOG} --test_all_versions # is parallel_tests 4 appropriate?
planemo test_reports ${TEST_JSON} --test_output ${TEST_HTML}
