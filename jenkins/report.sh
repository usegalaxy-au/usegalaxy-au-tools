#! /bin/bash
REPORT_DATE=$(env TZ="Australia/Queensland" date "+%Y-m-d")
REPORT_FILE="${REPORT_DATE}_tool_updates.md"
python scripts/write_report_from_log.py -j $BUILD_NUMBER > $REPORT_FILE

git clone https://github.com/galaxy-au-tools-jenkins-bot/website.git
cd website || exit 1
REPORT_DIR="_posts"
git remote add upstream git@github.com:usegalaxy-au/website.git
git checkout -b $REPORT_FILE
mv ../$REPORT_FILE _posts
git add $REPORT_DIR/$REPORT_FILE
git commit $REPORT_DIR/$REPORT_FILE -m "New and updated tools $REPORT_DATE"
git push --set-upstream origin/$REPORT_FILE
# hub pull-request -m "New and updated tools $REPORT_DATE"
