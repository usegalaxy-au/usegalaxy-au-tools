#! /bin/bash
SECRET_ENV_FILE=".secret.env"; # todo: run this script from within main.sh
[ -f $SECRET_ENV_FILE ] && LOCAL_ENV=1 || LOCAL_ENV=0
[ $LOCAL_ENV = 0 ] && VENV_PATH="/var/lib/jenkins/jobs_common" || VENV_PATH=".."
VIRTUALENV="$VENV_PATH/.venv3"
# shellcheck source=../.venv/bin/activate
. "$VIRTUALENV/bin/activate"

REPORT_DATE=$(env TZ="Australia/Queensland" date "+%Y-%m-%d")
REPORT_FILE="${REPORT_DATE}-tool-updates.md"
BRANCH_NAME="jenkins/${REPORT_DATE}-tool-updates"

command="python scripts/write_report_from_log.py -j $BUILD_NUMBER  -o $REPORT_FILE -d $REPORT_DATE"
echo $command
$command

if [ -f $REPORT_FILE ]; then
  git clone git@github.com:galaxy-au-tools-jenkins-bot/website.git
  cd website || exit 1

  git config --local user.name "galaxy-au-tools-jenkins-bot"
  git config --local user.email "galaxyaustraliatools@gmail.com"

  REPORT_DIR="_posts"
  git checkout -b $BRANCH_NAME
  mv ../$REPORT_FILE _posts
  git add $REPORT_DIR/$REPORT_FILE
  git commit $REPORT_DIR/$REPORT_FILE -m "New and updated tools $REPORT_DATE"
  git push --set-upstream origin $BRANCH_NAME
  hub pull-request -m "New and updated tools $REPORT_DATE"
else
  echo "No report generated for $REPORT_DATE"
fi
