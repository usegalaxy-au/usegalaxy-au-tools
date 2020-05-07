#! /bin/bash
chmod +x jenkins/install_tools.sh

MODE="$1"; # Two modes possible: "install" for tool request, "update" for cron update
ARGS=( "$@" )
FILE_ARGS=("${ARGS[@]:1}")
LOG_DIR=~/galaxy_tool_automation
BASH_V="$(echo ${BASH_VERSION} | head -c 1)" # this will be "4" if the bash version is 4.x, empty otherwise

FORCE=0
GIT_COMMIT_MESSAGE=$(git log --format=%B -n 1 $GIT_COMMIT | cat)
[[ $GIT_COMMIT_MESSAGE == *"[FORCE]"* ]] && FORCE=1;

if [ ! "$MODE" = "install" ] && [ ! "$MODE" = "update" ]; then
  echo "First positional argument to jenkins/main must be install or update"
  exit 1
fi

# Use RUN_SCRIPT_ON_JENKINS variable as a switch to allow the script to be run
# locally or remotely at stages of development. If RUN_SCRIPT_ON_JENKINS is 0,
# the script will only run where a .secret.env file is present. The .secret.env
# file is necessary for loading the API keys outside of the jenkins environment
RUN_SCRIPT_ON_JENKINS=1
SECRET_ENV_FILE=".secret.env"
[ -f $SECRET_ENV_FILE ] && LOCAL_ENV=1 || LOCAL_ENV=0
export LOCAL_ENV=$LOCAL_ENV

if [ $LOCAL_ENV = 1 ]; then
    # GIT_COMMIT and GIT_PREVIOUS_COMMIT are supplied by Jenkins
    # Use HEAD and HEAD~1 when running locally
    BUILD_NUMBER="local_$(date '+%Y%m%d%H%M%S')"
    GIT_PREVIOUS_COMMIT=HEAD~1;
    GIT_COMMIT=HEAD;
    LOG_DIR="logs"
    echo "Script running in local enviroment";
else
    echo "Script running on jenkins server";
    if [ $RUN_SCRIPT_ON_JENKINS = 0 ]; then
        echo "Skipping installation as RUN_SCRIPT_ON_JENKINS is set to 0 (false)";
    fi
fi

LOG_DIR=${LOG_DIR}/${MODE}_build_${BUILD_NUMBER}

export BUILD_NUMBER=$BUILD_NUMBER
export LOG_FILE="${LOG_DIR}/install_log.txt"
export GIT_COMMIT=$GIT_COMMIT
export GIT_PREVIOUS_COMMIT=$GIT_PREVIOUS_COMMIT
export LOG_DIR=$LOG_DIR
export BASH_V=$BASH_V
export MODE=$MODE
export FORCE=$FORCE

activate_virtualenv() {
  # Activate the virtual environment on jenkins. If this script is being run for
  # the first time we will need to set up the virtual environment
  # The venv is set up in Jenkins' home directory so that we do not have
  # to rebuild it each time and multiple jobs can share it
  VENV_PATH="/var/lib/jenkins/jobs_common"
  [ $LOCAL_ENV = 1 ] && VENV_PATH=".."
  VIRTUALENV="$VENV_PATH/.venv3"
  REQUIREMENTS_FILE="jenkins/requirements.yml"
  CACHED_REQUIREMENTS_FILE="$VIRTUALENV/cached_requirements.yml"

  [ ! -d $VENV_PATH ] && mkdir $VENV_PATH
  [ ! -d $VIRTUALENV ] && virtualenv -p python3 $VIRTUALENV
  # shellcheck source=../.venv3/bin/activate
  . "$VIRTUALENV/bin/activate"

  # if requirements change, reinstall requirements
  [ ! -f $CACHED_REQUIREMENTS_FILE ] && touch $CACHED_REQUIREMENTS_FILE
  if [ "$(diff $REQUIREMENTS_FILE $CACHED_REQUIREMENTS_FILE)" ]; then
    pip install -r $REQUIREMENTS_FILE
    cp $REQUIREMENTS_FILE $CACHED_REQUIREMENTS_FILE
  fi
}

jenkins_tool_installation() {
  if [ $MODE = "install" ]; then
    # First check whether changed files are in the path of tool requests, that is within the requests folder but not within
    # any subfolders of requests.  If so, we run the install script.  If not we exit.
    REQUESTS_DIFF=$(git diff --name-only --diff-filter=A $GIT_PREVIOUS_COMMIT $GIT_COMMIT | cat | grep "^requests\/[^\/]*$")

    # Arrange git diff into string "file1 file2 .. fileN"
    REQUEST_FILES=$REQUESTS_DIFF
    if [[ "$REQUESTS_DIFF" == *$'\n'* ]]; then
      REQUEST_FILES=$(echo $REQUESTS_DIFF | tr "\n" " ")
    fi

    if [ $LOCAL_ENV = 1 ] && [[ "$*" ]]; then # if running locally, allow a filename argument
      echo Running locally, installing "$*";
      REQUEST_FILES="$*";
    fi

    export REQUEST_FILES=$REQUEST_FILES

    if [[ ! $REQUEST_FILES ]]; then
      # Exit early and do not write a log if the commit does not contain request files
      echo "No added files in requests folder, no tool installation required";
      exit 0;
    else
      echo "Tools from the following files will be installed";
      echo $REQUEST_FILES;
    fi
  fi

  # Create log folder structure
  [ -d $LOG_DIR ] || mkdir -p $LOG_DIR;
  mkdir -p $LOG_DIR/staging;  # staging test json output
  mkdir -p $LOG_DIR/production;  # production test json output
  mkdir -p $LOG_DIR/planemo;  # planemo html output tools that fail tests

  activate_virtualenv
  echo "Saving output to $LOG_FILE"
  bash jenkins/install_tools.sh 2>&1 | tee $LOG_FILE
}

# Always run locally, if running on Jenkins run only when switched on (1)
if [ $LOCAL_ENV = 1 ] || [ $RUN_SCRIPT_ON_JENKINS = 1 ]; then
  jenkins_tool_installation "${FILE_ARGS[@]}"
fi
