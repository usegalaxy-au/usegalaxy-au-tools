STAGING_URL='https://galaxy-cat.genome.edu.au'  # TODO: when using this in production swap this to 'galaxy-aust-staging' (commented out below)
PRODUCTION_URL='https://cat-dev.genome.edu.au'  # TODO: when using this in production swap this to 'usegalaxy.org.au' (commented out below)
STAGING_DIR='galaxy-cat'  # TODO: when using this in production swap this to 'galaxy-aust-staging' (commented out below)
PRODUCTION_DIR='cat-dev'  # TODO: when using this in production swap this to 'usegalaxy.org.au' (commented out below)

# STAGING_DIR='galaxy-aust-staging'
# PRODUCTION_DIR='usegalaxy.org.au'

if [ ! $TRAVIS_PULL_REQUEST ] && [ ! "$@" = "local" ]; then
  exit 0;
fi

if [ "$@" = "local" ]; then
  TRAVIS_BRANCH=master
  export $(cat .env)
fi

# check the range of the commit input_file_paths
echo "TRAVIS_BRANCH: $TRAVIS_BRANCH"
echo "TRAVIS_PULL_REQUEST_BRANCH: $TRAVIS_PULL_REQUEST_BRANCH"

REQUEST_FILES=$(git diff --diff-filter=A --name-only $TRAVIS_BRANCH | cat | grep "^requests\/[^\/]*$")
JENKINS_CONTROLLED_FILES=$(git diff --name-only $TRAVIS_BRANCH | cat  | grep "^(?:\$STAGING_DIR\/|PRODUCTION_DIR\/).*/")

if [ $JENKINS_CONTROLLED_FILES ]; then
  echo 'Files within $PRODUCTION_DIR or $STAGING_DIR are written by Jenkins and cannot be altered';
  exit 1;
fi

echo $REQUEST_FILES
if [ ! "$REQUEST_FILES" ]; then
  echo 'No changed files in requests directory: there are no tests for this scenario';
  exit 0;
fi

FILE_ARGS=$REQUEST_FILES
if [ ! -f $REQUEST_FILES ]; then
  FILE_ARGS=$(tr "\n" " " < $REQUEST_FILES)
fi

# pass the requests file paths to a python script that checks the input files
python .travis/check_files.py -f $FILE_ARGS --staging_url $STAGING_URL --staging_api_key $STAGING_API_KEY --production_url $PRODUCTION_URL --production_api_key $PRODUCTION_API_KEY
