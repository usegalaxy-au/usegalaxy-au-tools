#! /bin/bash
source jenkins/utils.sh
activate_virtualenv

REPORT_DATE=$(env TZ="Australia/Queensland" date "+%Y-%m-%d")
REPORT_FILE="${REPORT_DATE}-tool-updates.md"
BRANCH_NAME="jenkins/${REPORT_DATE}-tool-updates"

command="python scripts/write_report_from_log.py -j $BUILD_NUMBER  -o $REPORT_FILE -d $REPORT_DATE"
echo $command
$command

if [ -f $REPORT_FILE ]; then
  git clone git@github.com:usegalaxy-au/website.git
  cd website || exit 1

  git config --local user.name "galaxy-au-tools-jenkins-bot"
  git config --local user.email "galaxyaustraliatools@gmail.com"

  REPORT_DIR="_posts"
  git checkout -b $BRANCH_NAME
  git reset --hard origin/master
  mv ../$REPORT_FILE $REPORT_DIR
  git add $REPORT_DIR/$REPORT_FILE
  git commit $REPORT_DIR/$REPORT_FILE -m "New and updated tools $REPORT_DATE"
  git push --set-upstream origin $BRANCH_NAME
  hub pull-request -m "New and updated tools $REPORT_DATE"
  curl -X POST -d "api_token=${WEBSITE_API_TOKEN}&tool_update=true&body=$(cat $REPORT_DIR/$REPORT_FILE)" http://usegalaxy-au.neoformit.com/news/api/create
else
  echo "No report generated for $REPORT_DATE"
fi
