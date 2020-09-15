#! /bin/bash
source .env

SECRET_ENV_FILE=".secret.env"; # todo: abstract this repeated block somehow
[ -f $SECRET_ENV_FILE ] && LOCAL_ENV=1 || LOCAL_ENV=0
[ $LOCAL_ENV = 0 ] && VENV_PATH="/var/lib/jenkins/jobs_common" || VENV_PATH=".."
VIRTUALENV="$VENV_PATH/.venv3"
# shellcheck source=$VIRTUALENV/bin/activate
. "$VIRTUALENV/bin/activate"

DISPLAY_NEW_DAYS='14'
DISPLAY_UPDATED_DAYS='14'
REMOTE_USER='galaxy'
FILE_PRODUCTION=/mnt/galaxy-app/config/shed_tool_conf.xml
FILE_STAGING=/mnt/galaxy/galaxy-app/config/shed_tool_conf.xml

python scripts/update_tool_panel_labels.py \
  --display_new_days $DISPLAY_NEW_DAYS \
  --display_updated_days $DISPLAY_UPDATED_DAYS \
  --remote_user $REMOTE_USER \
  --galaxy_url $STAGING_URL \
  --remote_file_path $FILE_STAGING \
  --safe

python scripts/update_tool_panel_labels.py \
  --display_new_days $DISPLAY_NEW_DAYS \
  --display_updated_days $DISPLAY_UPDATED_DAYS \
  --remote_user $REMOTE_USER \
  --galaxy_url $PRODUCTION_URL \
  --remote_file_path $FILE_PRODUCTION \
  --safe

