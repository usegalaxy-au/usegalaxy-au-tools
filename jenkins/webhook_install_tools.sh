#! /bin/bash

STAGING_URL=https://galaxy-cat.genome.edu.au ##
PRODUCTION_URL=https://cat-dev.genome.edu.au
STAGING_TOOL_DIR=galaxy-cat
PRODUCTION_TOOL_DIR=cat-dev
AUTOMATED_TOOL_INSTALLATION_LOG='automated_tool_installation_log.tsv'; # version controlled
LOG_HEADER="Jenkins Build Number\tInstall ID\tLog Path\tStatus\tFailing Step\tName"

install_tools() {
	echo Running automated tool installation script
	echo --------------------------
	echo STAGING_URL = $STAGING_URL
	echo PRODUCTION_URL = $PRODUCTION_URL
	echo STAGING_TOOL_DIR = $STAGING_TOOL_DIR
	echo PRODUCTION_TOOL_DIR = $PRODUCTION_TOOL_DIR

	# Jenkins build number
	echo BUILD_NUMBER = $BUILD_NUMBER
	echo INSTALL_ID = $INSTALL_ID
	echo GIT_COMMIT = $GIT_COMMIT
	echo GIT_PREVIOUS_COMMIT = $GIT_PREVIOUS_COMMIT
	echo -------------------------------

	# Virtual environment in build directory has ephemeris and bioblend installed.
	# If this script is being run for the first time we will need to set up the
	# virtual environment
	if [ $LOCAL_ENV = 0 ]; then
		VIRTUALENV="../.venv"
		if [ ! -d $VIRTUALENV ]; then
			echo "creating virtual environment";
		        virtualenv $VIRTUALENV;
			cd ..
			pip install ephemeris
			pip install bioblend
			cd workspace
		fi
		. $VIRTUALENV/bin/activate
	fi

	# Ensure log file exists, create it if not
	if [ ! -f $AUTOMATED_TOOL_INSTALLATION_LOG ]; then
		echo -e $LOG_HEADER > $AUTOMATED_TOOL_INSTALLATION_LOG;
		git add $AUTOMATED_TOOL_INSTALLATION_LOG; # this has to be a tracked file
	fi

	# Arrange git diff into string "file1 file2 .. fileN"
	FILE_ARGS=$REQUESTS_DIFF
	if [ ! -f $REQUESTS_DIFF ]; then
		FILE_ARGS=$(tr "\n" " " < $REQUESTS_DIFF)
	fi

	if [ $LOCAL_ENV = 0 ]; then
		# enable pushing to github.  there is almost certainly a better way to do this
		git remote set-url origin git@github.com:cat-bro/usegalaxy-au-tools.git
		eval `ssh-agent`
		ssh-add ~/.ssh/github_catbro_au_tools.rsa
		# make sure we are not in detached head state by checking out master
		git checkout master
		git pull
	fi

	TOOL_FILE_PATH="requests/pending/$INSTALL_ID/"
	mkdir -p $TOOL_FILE_PATH

	# split requests into individual yaml files in requests/pending
	# one file per unique revision so that installation can be run sequentially and
	# failure of one installation will not affect the others
	python scripts/organise_request_files.py -f $FILE_ARGS -o $TOOL_FILE_PATH

	NUM_TOOLS_TO_INSTALL=$(ls $TOOL_FILE_PATH | wc -l)
	INSTALLED_TOOL_COUNTER=0

	for FILE_NAME in $(ls $TOOL_FILE_PATH)
	do
		TOOL_FILE=$TOOL_FILE_PATH$FILE_NAME
		TOOL_REF=$(echo $FILE_NAME | cut -d'.' -f 1)
		TOOL_NAME=$(echo $(grep -oE "name: (\w+)" "$TOOL_FILE") | awk '{print $2}');

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

	echo "$INSTALLED_TOOL_COUNTER out of $NUM_TOOLS_TO_INSTALL tools installed."
	if [ ! "$LOG_ENTRY" ]; then
		echo "WARNING: No log entry stored";
	else
		echo "Writing entry to $AUTOMATED_TOOL_INSTALLATION_LOG"
		echo "=================================================="
		echo -e $LOG_HEADER
		echo -e $LOG_ENTRY
		echo "=================================================="
		echo -e $LOG_ENTRY >> $AUTOMATED_TOOL_INSTALLATION_LOG;

		update_tool_list "STAGING"
		update_tool_list "PRODUCTION"

		# Push changes to github
		# Add any new tool list files that have been created.
		for $YML_FILE in $(ls $STAGING_TOOL_DIR)                                                                                                                                                 catherine@catherines-mbp
	  do
	    git add $STAGING_TOOL_DIR/$YML_FILE ||:
	  done
		for $YML_FILE in $(ls $PRODUCTION_TOOL_DIR)                                                                                                                                                 catherine@catherines-mbp
	  do
	    git add $PRODUCTION_TOOL_DIR/$YML_FILE ||:
	  done

		for FILE_NAME in $(ls $TOOL_FILE_PATH)
		do
			git add $TOOL_FILE_PATH$FILE_NAME
		done
		for FILE_NAME in $REQUESTS_DIFF
		do
			git rm $FILE_NAME
		done

		# For the benefit of development log ALL git changes, per file
		for filepath in $(git diff --name-only | cat)
		do
			git diff $filepath | cat
			echo
		done
		COMMIT_MESSAGE="Jenkins build $BUILD_NUMBER."

		echo -e "\nPushing Changes to github"
		git commit -a -m "$COMMIT_MESSAGE"
		git push
		echo -e "\nDone"
	fi
}

# TODO all calls to shed-tools need to catch errors

test_tool() {
	# Positional arguments: $1 = STAGING|PRODUCTION, $2 = tool file path
	TOOL_FILE="$2"
	SERVER="$1"
	if [ $SERVER = "STAGING" ]; then
		API_KEY=$STAGING_API_KEY
		URL=$STAGING_URL
		TEST_JSON="$LOG_DIR"/"$INSTALL_ID"_staging_test.json
		STEP="Staging Testing"
	elif [ $SERVER = "PRODUCTION" ]; then
		API_KEY=$PRODUCTION_API_KEY
		URL=$PRODUCTION_URL
		TEST_JSON="$LOG_DIR"/"$INSTALL_ID"_production_test.json
		STEP="Production Testing"
	else
		echo "First positional argument must be STAGING or PRODUCTION.  Exiting"
		return 1
	fi

	TEST_LOG='tmp/test_log.txt'
	rm -f $TEST_LOG ||:;  # delete if it does not exist

	command="shed-tools test -g $URL -a $API_KEY -t $TOOL_FILE --parallel_tests 4 --test_json $TEST_JSON -v --log_file $TEST_LOG"
	echo "${command/$API_KEY/<API_KEY>}"
	$command || return 1
	echo
	if [ $BASH_V = 4 ]; then
		# normal regex
		[[ $(cat $INSTALL_LOG) =~ "Passed tool tests \((\d+)\)" ]];
		TESTS_PASSED="${BASH_REMATCH[1]}"
		[[ $(cat $INSTALL_LOG) =~ "Failed tool tests \((\d+)\)" ]];
		TESTS_FAILED="${BASH_REMATCH[1]}"
		echo $TESTS_PASSED
		echo $TESTS_FAILED
	else
		# resort to python helper
		TESTS_PASSED="$(python scripts/first_match_regex.py -p 'Passed tool tests \((\d+)\)' $TEST_LOG)"
		TESTS_FAILED="$(python scripts/first_match_regex.py -p 'Failed tool tests \((\d+)\)' $TEST_LOG)"
	fi
	if [ $TESTS_FAILED = 0 ]; then
		if [ $TESTS_PASSED = 0 ]; then
			echo "WARNING: There are no tests for $TOOL_NAME at revision $INSTALLED_REVISION.  Proceeding as none have failed.";
		else
			echo "All tests have passed for $TOOL_NAME at revision $INSTALLED_REVISION on $URL.";
		fi
		if [ "$SERVER" = "PRODUCTION" ]; then
			unset STEP
			log_row "Success"
			exit_installation 0 ""
			return 0
		fi
		echo -e "\nSuccessfully installed $TOOL_NAME on $URL\n";
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
		exit_installation 1 ""
		return 1
	fi
}

install_tool() {
	# Positional arguments: $1 = STAGING|PRODUCTION, $2 = tool file path, $3 = repeat (default 1)
	if [ "$3" ]; then
		REPEAT="$3";
	else
		REPEAT=1
	fi

	TOOL_FILE="$2"
	SERVER="$1"
	if [ $SERVER = "STAGING" ]; then
		API_KEY=$STAGING_API_KEY
		URL=$STAGING_URL
		STEP="Staging Installation"
	elif [ $SERVER = "PRODUCTION" ]; then
		API_KEY=$PRODUCTION_API_KEY
		URL=$PRODUCTION_URL
		STEP="Production Installation"
	else
		echo "First positional argument must be STAGING or PRODUCTION.  Exiting"
		return 1
	fi

	INSTALL_LOG='tmp/install_log.txt'
	rm -f $INSTALL_LOG ||:;  # delete if it does not exist

	# Ephemeris install script
	command="shed-tools install -g $URL -a $API_KEY -t $TOOL_FILE -v --log_file $INSTALL_LOG"
	echo "${command/$API_KEY/<API_KEY>}"; # substitute API_KEY for printing
	$command || return 1

	# Capture the status (Installed/Skipped/Errored), name and revision hash from ephemeris output
	if [ $BASH_V = 4 ]; then
		PATTERN="(\w+) repositories \(1\): \[\('([^']+)',\s*u?'(\w+)'\)\]"
		[[ $(cat $INSTALL_LOG) =~ $PATTERN ]];
		INSTALLATION_STATUS="${BASH_REMATCH[1]}";
		INSTALLED_NAME="${BASH_REMATCH[2]}";
		INSTALLED_REVISION="${BASH_REMATCH[3]}";
		echo $INSTALLATION_STATUS
		echo $INSTALLED_NAME
		echo $INSTALLED_REVISION
	else # the regex above does not work on my local machine (Mac), hence this python workaround
		SHED_TOOLS_VALUES=($(python scripts/first_match_regex.py -p "(\w+) repositories \(1\): \[\('([^']+)',\s*u?'(\w+)'\)\]" $INSTALL_LOG));
	fi
	if [ $SHED_TOOLS_VALUES ]; then
		INSTALLATION_STATUS="${SHED_TOOLS_VALUES[0]}";
		INSTALLED_NAME="${SHED_TOOLS_VALUES[1]}";
		INSTALLED_REVISION="${SHED_TOOLS_VALUES[2]}";
	fi
	# If all three values are not null, proceed only if status is Installed,
	# write log entry and leave otherwise
	if [ "$INSTALLATION_STATUS" ] && [ "$INSTALLED_NAME" ] && [ "$INSTALLED_REVISION" ]; then
		if [ ! $INSTALLATION_STATUS = 'Installed' ]; then
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
				echo "Halting unsuccessful installation";
			elif [ $INSTALLATION_STATUS = "Skipped" ]; then
				# Note that linting process should prevent this scenario
				echo "Package appears to be already installed on $URL";
			fi
			log_row $INSTALLATION_STATUS
			exit_installation 1 ""
			# TODO: Should files be moved elsewhere?
			return 1;
		else
			if [ ! "$TOOL_NAME" = "$INSTALLED_NAME" ]; then
				# Sanity check.  If these are not the same name, uninstall and abandon process with 'Script error'
				python scripts/uninstall_tools.py -g $URL -a $API_KEY -n $INSTALLED_NAME;
				log_row "Script Error"
				exit_installation 1 ""
				return 1
			fi
		fi
		else
			# TODO what if this is production server?  wind back staging installation?
			log_row "Script error"
			exit_installation 1 "Could not verify installation from shed-tools output."
			return 1
	fi
}

log_row() {
	# 'Jenkins Build Number\tInstall ID\tLog Path\tStatus\tFailing Step\tName'
	# TODO: What are relevant log values?  Owner.  Revision.  Section.  Toolshed URL. Start time.  Finish time.  Elapsed time.
	STATUS="$1"
	if [ "$LOG_ENTRY" ]; then
		LOG_ENTRY="$LOG_ENTRY\n";	# If log entry has content, add new line before new content
	fi
	LOG_ROW="$BUILD_NUMBER\t$INSTALL_ID\t$LOG_FILE\t$STATUS\t$STEP\t$TOOL_NAME"
  LOG_ENTRY="$LOG_ENTRY$LOG_ROW"
	# echo -e $LOG_ROW; # Need to print this values?  Store them in multiD array? What if script stops in the middle?
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
		echo "First positional argument must be STAGING or PRODUCTION.  Exiting"
		return 1
	fi

	TMP_TOOL_FILE=tmp/tool_list.yml
	rm -f $TMP_TOOL_FILE ||:; # remove file if it exists
	get-tool-list -g $URL -a $API_KEY -o $TMP_TOOL_FILE --get_data_managers
	python scripts/split_tool_yml.py -i $TMP_TOOL_FILE -o $TOOL_DIR; # Simon's script
}

install_tools
