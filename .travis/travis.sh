STAGING_DIR='galaxy-cat'  # TODO: when using this in production swap this to 'galaxy-aust-staging' (commented out below)
PRODUCTION_DIR='cat-dev'  # TODO: when using this in production swap this to 'usegalaxy.org.au' (commented out below)

# STAGING_DIR='galaxy-aust-staging'
# PRODUCTION_DIR='usegalaxy.org.au'

if [ ! $TRAVIS_PULL_REQUEST ] && [ ! "$@" = "local" ]; then
  exit 0;
fi

# check the range of the commit input_file_paths
echo "TRAVIS_BRANCH: $TRAVIS_BRANCH"
echo "TRAVIS_PULL_REQUEST_BRANCH: $TRAVIS_PULL_REQUEST_BRANCH"
CHANGED_FILES=$(git diff --diff-filter=A --name-only $TRAVIS_BRANCH)
echo ________________
echo "git diff --name-only --diff-filter=A $TRAVIS_BRANCH"
echo $CHANGED_FILES
echo ________________
REQUEST_FILES=$(echo $CHANGED_FILES | grep "^requests\/[^\/]*$")
JENKINS_CONTROLLED_FILES=$(echo $CHANGED_FILES | grep "^(?:\$STAGING_DIR\/|PRODUCTION_DIR\/).*/")

if [ $JENKINS_CONTROLLED_FILES ]; then
  echo 'Files within $PRODUCTION_DIR or $STAGING_DIR are written by Jenkins and cannot be altered';
  exit 1;
fi

if [ ! $REQUEST_FILES ]; then
  echo 'No changed files in requests directory: there are no tests for this scenario';
  exit 0;
fi

FILE_ARGS=$REQUEST_FILES
if [ ! -f $REQUESTS_FILES ]; then
  FILE_ARGS=$(tr "\n" " " < $REQUESTS_FILES)
fi

# pass the requests file paths to a python script that checks the yml
python .travis/travis_check_files.py -f $FILE_ARGS
