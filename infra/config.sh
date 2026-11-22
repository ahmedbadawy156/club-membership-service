# Shared settings for the infra scripts. Sourced, not run.
# Nothing here is secret: Floci uses the fake account 000000000000.

export AWS_PROFILE="${AWS_PROFILE:-floci}"
export AWS_PAGER=""
export MSYS_NO_PATHCONV=1   # stop Git Bash turning /api/... into Windows paths

# Use the AWS CLI from PATH, or the default Windows install location.
if command -v aws >/dev/null 2>&1; then
  AWS=aws
elif [ -x "/c/Program Files/Amazon/AWSCLIV2/aws.exe" ]; then
  AWS="/c/Program Files/Amazon/AWSCLIV2/aws.exe"
else
  echo "AWS CLI not found. Install AWS CLI v2 and open a new terminal." >&2
  exit 1
fi

ACCOUNT=000000000000
REGION=us-east-1

FUNCTION=club-membership-api
ROLE=club-membership-role
ROLE_POLICY=club-membership-access
API_NAME=club-membership-http-api
LOG_GROUP=/aws/lambda/$FUNCTION

# Website origins allowed by CORS. On Floci the S3 website is served from
# http://localhost:4566; add the local dev frontend while developing.
CORS_ORIGINS="${CORS_ORIGINS:-http://localhost:4566}"

# Address of an API on Floci (works while the PC can resolve localhost.floci.io).
api_url() { echo "http://$1.execute-api.localhost.floci.io:4566"; }
