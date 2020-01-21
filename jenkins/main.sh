#! /bin/bash
chmod +x jenkins/webhook_install_tools.sh

export GIT_COMMIT="$GIT_COMMIT"
export GIT_PREVIOUS_COMMIT="$GIT_PREVIOUS_COMMIT"
export BUILD_NUMBER="$BUILD_NUMBER"
export INSTALL_ID="$(date '+%Y%m%d%H%M%S')" # this will do for now, could incorporate jenkins build ID or git commit hash
export LOG_DIR=~/galaxy_tool_automation
export BASH_V="$(echo ${BASH_VERSION} | head -c 1)" # this will be "4" if the bash version is 4.x, empty otherwise

# Switch to allow the script to be run locally or remotely at stages of development
# if RUN_LOCALLY is true, the script will only run where an .env file is present
RUN_LOCALLY=0 # (1) Disable script on jenkins (0) run script on jenkins
export LOCAL_ENV=0
RUN=1 # true=1, false=0
FILE=.env
if [ -f "$FILE" ]; then
		export LOCAL_ENV=1
		export LOG_DIR=logs
		export $(cat .env)
		GIT_PREVIOUS_COMMIT=HEAD~1
		GIT_COMMIT=HEAD
		if [ $@ ]; then
			# Allow filename to be provided as argument if running locally
			export SUPPLIED_FILENAME=$@;
		fi
    echo 'Script running in local enviroment';
else
		echo 'Script running on jenkins server';
		if [ $RUN_LOCALLY = 1 ]; then
				echo 'Skipping installation as RUN_LOCALLY is set to 1 (true)';
				RUN=0;
		fi
fi

if [ ! -d LOG_DIR ]; then
	mkdir $LOG_DIR
fi
export LOG_FILE="$LOG_DIR/webhook_tool_installation_$INSTALL_ID"

jenkins_tool_installation() {
	# First check whether changed files are in the path of tool requests, that is within the requests folder but not within
	# any subfolders of requests.  If so, we run the install script.  If not we exit.
	export REQUESTS_DIFF=$(git diff --name-only --diff-filter=A $GIT_PREVIOUS_COMMIT $GIT_COMMIT | cat | grep "^requests\/[^\/]*$")

	if [ ! $REQUESTS_DIFF ]; then
		if [ $LOCAL_ENV = 1 ] && [ $SUPPLIED_FILENAME ]; then # if running locally, allow a filename argument
			echo Running locally, installing $SUPPLIED_FILENAME;
			export REQUESTS_DIFF=$SUPPLIED_FILENAME;
		else
			echo 'No added files in requests folder, no tool installation required';
			exit 0;
		fi
	else
		echo 'Tools from the following files will be installed';
		echo $REQUESTS_DIFF;
	fi

	echo Saving output to $LOG_FILE
	if [ $LOCAL_ENV = 0 ]; then
		bash jenkins/webhook_install_tools.sh &> $LOG_FILE
		cat $LOG_FILE
	else
		# Do not save a log file when running locally
		bash jenkins/webhook_install_tools.sh
	fi
}

if [ $RUN = 1 ]; then
	jenkins_tool_installation
fi
