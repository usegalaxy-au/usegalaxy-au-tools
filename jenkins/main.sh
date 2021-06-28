#! /bin/bash
AUTOMATED_TOOL_INSTALLATION_LOG="automated_tool_installation_log.tsv"; # version controlled log file of all tools installed
LOG_HEADER="Category\tBuild Num.\tDate (AEST)\tName\tNew Tool\tStatus\tOwner\tInstalled Revision\tRequested Revision\tFailing Step\tStaging tests passed\tProduction tests passed\tSection Label\tTool Shed URL\tLog Path"

source jenkins/utils.sh
source jenkins/install_tools.sh
source ".env"

MODE="$1"; # Two modes possible: "install" for tool request, "update" for cron update
ARGS=( "$@" )
FILE_ARGS=("${ARGS[@]:1}")
[ ! $BASE_LOG_DIR ] && BASE_LOG_DIR=~/galaxy_tool_automation

if [ ! "$MODE" = "install" ] && [ ! "$MODE" = "update" ]; then
  echo "First positional argument to jenkins/main must be install or update"
  exit 1
fi

SECRET_ENV_FILE=".secret.env"
if [ -f $SECRET_ENV_FILE ]; then
    source $SECRET_ENV_FILE
    LOCAL_ENV=1
    # GIT_COMMIT and GIT_PREVIOUS_COMMIT are supplied by Jenkins
    # Use HEAD and HEAD~1 when running locally
    BUILD_NUMBER="local_$(date '+%Y%m%d%H%M%S')"
    GIT_PREVIOUS_COMMIT=HEAD~1;
    GIT_COMMIT=HEAD;
    BASE_LOG_DIR="logs"
    echo "Script running in local enviroment";
else
    LOCAL_ENV=0
    echo "Script running on jenkins server";
fi

if [ $MODE = "install" ]; then
  # First check whether changed files are in the path of tool requests, that is within the requests folder but not within
  # any subfolders of requests.
  REQUEST_FILES=$(git diff --name-only --diff-filter=A $GIT_PREVIOUS_COMMIT $GIT_COMMIT | grep "^requests\/[^\/]*$" | xargs)

  if [ $LOCAL_ENV = 1 ]; then # if running locally, allow a filename argument
    REQUEST_FILES="${FILE_ARGS[@]}";
    echo Running locally, installing "$REQUEST_FILES";
  fi

  if [[ ! $REQUEST_FILES ]]; then
    # Exit early and do not write a log if the commit does not contain request files
    echo "No added files in requests folder, no tool installation required";
    exit 0;
  else
    echo "Tools from the following files will be installed";
    echo $REQUEST_FILES;
  fi

  # Look for the word [FORCE] in COMMIT_MESSAGE. Set 'FORCE' variable to 1 to skip testing
  GIT_COMMIT_MESSAGE=$(git log --format=%B -n 1 $GIT_COMMIT | cat)
  [[ $GIT_COMMIT_MESSAGE == *"[FORCE]"* ]] && FORCE=1 || FORCE=0;
fi

# Create log folder structure
LOG_DIR=${BASE_LOG_DIR}/${MODE}_build_${BUILD_NUMBER}
[ -d $LOG_DIR ] || mkdir -p $LOG_DIR;
mkdir -p $LOG_DIR/staging;  # staging test json output
mkdir -p $LOG_DIR/production;  # production test json output
mkdir -p $LOG_DIR/planemo;  # planemo html output tools that fail tests
WORKING_INSTALLATION_LOG="${LOG_DIR}/installation_log.tsv";
LOG_FILE="${LOG_DIR}/install_log.txt"

activate_virtualenv
echo "Saving output to $LOG_FILE"
install_tools 2>&1 | tee $LOG_FILE
