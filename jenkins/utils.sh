#! /bin/bash

source .env

activate_virtualenv() {
  # Activate the virtual environment on jenkins. If this script is being run for
  # the first time we will need to set up the virtual environment
  # The venv is set up in Jenkins' home directory so that we do not have
  # to rebuild it each time and multiple jobs can share it
  VENV_PATH=${VENV_PATH:-..}
  [ "${LOCAL_ENV:-0}" = "1" ] && VENV_PATH=".."
  VIRTUALENV="$VENV_PATH/.venv3"
  REQUIREMENTS_FILE="jenkins/requirements.yml"
  CACHED_REQUIREMENTS_FILE="$VIRTUALENV/cached_requirements.yml"

  [ ! -d $VENV_PATH ] && mkdir $VENV_PATH
  [ ! -d $VIRTUALENV ] && virtualenv -p python311 $VIRTUALENV
  # shellcheck source=../.venv3/bin/activate
  . "$VIRTUALENV/bin/activate"

  # if requirements change, reinstall requirements
  [ ! -f $CACHED_REQUIREMENTS_FILE ] && touch $CACHED_REQUIREMENTS_FILE
  if [ "$(diff $REQUIREMENTS_FILE $CACHED_REQUIREMENTS_FILE)" ]; then
    pip install -r $REQUIREMENTS_FILE
    cp $REQUIREMENTS_FILE $CACHED_REQUIREMENTS_FILE
  fi
}

# Just use python to get titlecase and lowercase
title() {
  python -c "print('$1'.title())"
}

lower() {
  python -c "print('$1'.lower())"
}
