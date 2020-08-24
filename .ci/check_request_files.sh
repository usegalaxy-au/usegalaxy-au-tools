#! /bin/bash

# This script will run for a pull request or will run locally if the argument
# 'local' is provided
if [ ! $COMMIT_RANGE ] && [ ! "$1" = "local" ]; then
  exit 0;
fi

source .env  # Load non-secret enviroment variables e.g. $STAGING_URL

if [ "$1" = "local" ]; then
  COMMIT_RANGE=master
fi

# Added files in requests directory
REQUEST_FILES=$(git diff --diff-filter=A --name-only $COMMIT_RANGE | cat | grep "^requests\/[^\/]*$")

# Altered files in tool directories (eg. galaxy-aust-staging) written to by jenkins
JENKINS_CONTROLLED_FILES=$(git diff --name-only $COMMIT_RANGE | cat  | grep "^(?:\$STAGING_TOOL_DIR\/|PRODUCTION_TOOL_DIR\/).*/")

if [ $JENKINS_CONTROLLED_FILES ]; then
  echo "Files within $PRODUCTION_TOOL_DIR or $STAGING_TOOL_DIR are written by Jenkins and cannot be altered";
  exit 1;
fi

if [ ! "$REQUEST_FILES" ]; then
  echo "No added files in requests directory";
  exit 0;
fi

# pass the requests file paths to a python script that checks the input files
python .ci/check_files.py -f $REQUEST_FILES --staging_url $STAGING_URL --production_url $PRODUCTION_URL --staging_dir $STAGING_TOOL_DIR --production_dir $PRODUCTION_TOOL_DIR
