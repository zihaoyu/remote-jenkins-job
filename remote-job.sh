#!/usr/bin/env bash
###
# Trigger a Remote Jenkins Job with parameters and get console output as well as result
# Usage:
# remote-job.sh -u https://jenkins-url.com -j JOB_NAME -t BUILD_TOKEN -s JENKINS_USER -r API_TOKEN -p "PARAM1=999" -p "PARAM2=123"
# -u: url of jenkins host
# -j: JOB_NAME on jenkins host
# -p: parameter to pass in. Send multiple parameters by passing in multiple -p flags
# -t: BUILD_TOKEN on remote machine to run job
# -s: Jenkins user on remote machine to authenticate
# -r: Jenkins user API token on remote machine to authenticate
# -i: Tell curl to ignore cert validation
###

# Number of seconds before timing out
[ -z "$BUILD_TIMEOUT_SECONDS" ] && BUILD_TIMEOUT_SECONDS=3600
# Number of seconds between polling attempts
[ -z "$POLL_INTERVAL" ] && POLL_INTERVAL=10
while getopts j:p:t:u:s:r:i:w:f opt; do
  case $opt in
    p) parameters+=("$OPTARG");;
    t) parameters+=("token=$OPTARG");;
    j) JOB_NAME=$OPTARG;;
    u) JENKINS_URL=$OPTARG;;
    s) JENKINS_USER=$OPTARG;;
    r) API_TOKEN=$OPTARG;;
    i) CURL_OPTS="-k";;         # tell curl to ignore cert validation
    w) WAIT_TO_FINISH="true";;  # wait for remote build to finish
    f) WRITE_TO_FILE="true"     # write remote JOB_URL to properties file
    #...
  esac
done
shift $((OPTIND -1))

[ -z "$JENKINS_URL" ] && { logger -s "[ERROR] $(date) JENKINS_URL (-u) not set"; exit 1; }
logger -s "[INFO] $(date) JENKINS_URL: $JENKINS_URL"
[ -z "$JOB_NAME" ] && { logger -s "[ERROR] $(date) JOB_NAME (-j) not set"; exit 1; }
JOB_NAME=${JOB_NAME// /%20}
logger -s "[INFO] $(date) JOB_NAME: $JOB_NAME"

logger -s "[INFO] $(date) The whole list of values is '${parameters[@]}'"
for parameter in "${parameters[@]}"; do
  # If PARAMS exists, add an ampersand
  [ -n "$PARAMS" ] && PARAMS=$PARAMS\&$parameter
  # If no PARAMS exist, don't add an ampersand
  [ -z "$PARAMS" ] && PARAMS=$parameter
done
[ -z "$PARAMS" ] && { logger -s "[ERROR] $(date) No parameters were set!"; exit 1; }
logger -s "[INFO] $(date) PARAMS: $PARAMS"

PROPERTIES_FILE=remote_build.properties
echo "REMOTE_JENKINS_URL=$JENKINS_URL" > $PROPERTIES_FILE

# Queue up the job
# nb You must use the buildWithParameters build invocation as this
# is the only mechanism of receiving the "Queued" job id (via HTTP Location header)

REMOTE_JOB_URL="$JENKINS_URL/job/$JOB_NAME/buildWithParameters?$PARAMS"
logger -s "[INFO] $(date) Calling REMOTE_JOB_URL: $REMOTE_JOB_URL"

QUEUED_URL=$(curl -XPOST -sSL --user $JENKINS_USER:$API_TOKEN $CURL_OPTS -D - "$REMOTE_JOB_URL" | grep -i Location | awk {'print $2'})
QUEUED_NUMBER=$(echo $QUEUED_URL | rev | cut -f2 -d'/' | rev)
#perl -n -e '/^Location: (.*)$/ && print "$1\n"')
[ -z "$QUEUED_URL" ] && { logger -s "[ERROR] $(date) No QUEUED_URL was found.  Did you remember to set a token (-t)?"; exit 1; }

echo "QUEUED_NUMBER=$QUEUED_NUMBER" >> $PROPERTIES_FILE

# Remove extra \r at end, add /api/json path
QUEUED_URL=${QUEUED_URL%$'\r'}api/json

# Fetch the executable.url from the QUEUED url
SCHEDULED="false"
JOB_URL=`curl -XPOST -sSL --user $JENKINS_USER:$API_TOKEN $QUEUED_URL | jq -r '.executable.url'`
[ "$JOB_URL" = "null" ] && unset JOB_URL
# Check for status of queued job, whether it is running yet
COUNTER=0
while [ -z "$JOB_URL" ]; do
  logger -s "[INFO] $(date) The QUEUED counter is $COUNTER"
  let COUNTER=COUNTER+$POLL_INTERVAL
  sleep $POLL_INTERVAL
  if [ "$COUNTER" -gt $BUILD_TIMEOUT_SECONDS ];
  then
    logger -s "[ERROR] $(date) TIMEOUT: Exceeded $BUILD_TIMEOUT_SECONDS seconds"
    break
  fi
  JOB_URL=`curl -XPOST -sSL --user $JENKINS_USER:$API_TOKEN $CURL_OPTS $QUEUED_URL | jq -r '.executable.url'`
  SCHEDULED="true"
  [ "$JOB_URL" = "null" ] && unset JOB_URL && SCHEDULED="false"
done
logger -s "[INFO] $(date) REMOTE_BUILD_URL: $JOB_URL"
echo "SCHEDULED=$SCHEDULED" >> $PROPERTIES_FILE

if [ "$SCHEDULED" = "false" ]; then
  # timeout and our job is not scheduled. Exit
  logger -s "[ERROR] $(date) Our build is not scheduled. Exiting..."
  exit 1
fi

# Job is running
IS_BUILDING="false"
COUNTER=0

# Use until IS_BUILDING = false (instead of while IS_BUILDING = true)
# to avoid false positives if curl command (IS_BUILDING) fails
# while polling for status
until [ "$IS_BUILDING" = "true" ]; do
  let COUNTER=COUNTER+$POLL_INTERVAL
  sleep $POLL_INTERVAL
  if [ "$COUNTER" -gt $BUILD_TIMEOUT_SECONDS ];
  then
    logger -s "[ERROR] $(date) TIMEOUT: Exceeded $BUILD_TIMEOUT_SECONDS seconds"
    break
  fi
  IS_BUILDING=`curl -XPOST -sSL --user $JENKINS_USER:$API_TOKEN $CURL_OPTS $JOB_URL/api/json | jq -r '.building'`
done

# Write remote build url to file
if [ "$WRITE_TO_FILE" = "true" ]; then
  echo "REMOTE_BUILD_URL=$JOB_URL" >> $PROPERTIES_FILE
fi

if [ "$IS_BUILDING" = "false" ]; then
  # our build is not building
  logger -s "[ERROR] $(date) Our build is not being built. Exiting..."
  exit 1
fi

# Wait for remote build to finish if requested
if [ "$WAIT_TO_FINISH" = "true" ]; then
  RESULT=`curl -XPOST -sSL --user $JENKINS_USER:$API_TOKEN $CURL_OPTS $JOB_URL/api/json | jq -r '.result'`
  if [ "$RESULT" = 'SUCCESS' ]
  then
    logger -s "[INFO] $(date) BUILD RESULT: $RESULT"
    exit 0
  else
    logger -s "[ERROR] $(date) BUILD RESULT: $RESULT - Build is unsuccessful, timed out, or status could not be obtained."
    exit 1
  fi
fi
