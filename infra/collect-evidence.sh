#!/usr/bin/env bash
# Collect evidence for the final report into evidence/:
#   evidence/test-results.txt     every test suite, full output
#   evidence/floci-resources.txt  what is deployed on Floci (no secret values)
#   evidence/secret-scan.txt      checks that no secret is in Git or the site
#   bash infra/collect-evidence.sh        (after bash infra/deploy.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh
mkdir -p evidence

echo "== 1/3 Test suites"
bash tests/run-all.sh
cp infra/out/test-results.txt evidence/test-results.txt

echo "== 2/3 Floci resource listings"
source infra/out/api.env
{
  echo "# Floci resources for the Membership service ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo "# Account: $("$AWS" sts get-caller-identity --query Account --output text)   Region: $REGION"
  echo "# Floci IAM enforcement: $(docker exec floci printenv FLOCI_SERVICES_IAM_ENFORCEMENT_ENABLED 2>/dev/null)"
  echo; echo "## DynamoDB tables"
  for t in $("$AWS" dynamodb list-tables --query 'TableNames' --output text); do
    printf '%-20s status=%s items=%s indexes=%s\n' "$t" \
      "$("$AWS" dynamodb describe-table --table-name "$t" --query 'Table.TableStatus' --output text)" \
      "$("$AWS" dynamodb describe-table --table-name "$t" --query 'Table.ItemCount' --output text)" \
      "$("$AWS" dynamodb describe-table --table-name "$t" --query 'Table.GlobalSecondaryIndexes[].IndexName' --output text | tr '\t' ',')"
  done
  echo "RateLimits TTL: $("$AWS" dynamodb describe-time-to-live --table-name RateLimits --query 'TimeToLiveDescription.[TimeToLiveStatus,AttributeName]' --output text)"
  echo; echo "## Lambda function (environment variable NAMES only)"
  "$AWS" lambda get-function-configuration --function-name "$FUNCTION" \
    --query '{Name:FunctionName,Runtime:Runtime,Handler:Handler,Role:Role,Timeout:Timeout,Memory:MemorySize,State:State}' --output table
  echo "Environment variable names: $("$AWS" lambda get-function-configuration --function-name "$FUNCTION" --query 'keys(Environment.Variables)' --output text | tr '\t' ' ')"
  echo; echo "## API Gateway $API_NAME ($API_URL)"
  "$AWS" apigatewayv2 get-routes --api-id "$API_ID" --query 'sort_by(Items,&RouteKey)[].RouteKey' --output text | tr '\t' '\n' | sed 's/^/  /'
  echo; echo "## IAM role $ROLE"
  echo "Trust: $("$AWS" iam get-role --role-name "$ROLE" --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text)"
  echo "Inline policies: $("$AWS" iam list-role-policies --role-name "$ROLE" --query 'PolicyNames' --output text)"
  echo "(policy document: infra/iam/membership-policy.json)"
  echo; echo "## Secrets Manager (name and keys only, never values)"
  echo "Secret: $("$AWS" secretsmanager describe-secret --secret-id "$SECRET_ID" --query 'Name' --output text)"
  echo "Keys: $("$AWS" secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(Object.keys(JSON.parse(s)).join(", ")))')"
  echo; echo "## CloudWatch Logs $LOG_GROUP (latest request lines)"
  "$AWS" logs tail "$LOG_GROUP" --since 30m --format short 2>/dev/null | grep -E ' (GET|POST|PATCH|OPTIONS) /api/' | tail -12 | awk '{$1=""; print}'
  echo; echo "## S3 website bucket club-web"
  "$AWS" s3 ls s3://club-web --recursive 2>/dev/null | awk '{print "  " $4}'
} > evidence/floci-resources.txt
echo "   saved evidence/floci-resources.txt"

echo "== 3/3 Secret scan"
{
  echo "# Secret scan ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo "private keys in the whole Git history: $(git log --all -p | grep -c 'BEGIN .*PRIVATE KEY')"
  echo ".env / secret files ever committed: $(git log --all --name-only --format= | grep -cE '(^|/)\.env$|secret\.tmp|infra/keys/|infra/out/')"
  echo "Supabase secret keys in history: $(git log --all -p | grep -cE 'sb_secret_[A-Za-z0-9]')"
  echo "private key text in the S3 site: $("$AWS" s3 sync s3://club-web infra/out/site-copy --only-show-errors >/dev/null 2>&1; grep -rlE 'PRIVATE KEY|sb_secret_' infra/out/site-copy 2>/dev/null | wc -l | tr -d ' ')"
  echo "note: the earlier Supabase prototype committed the local Supabase CLI's default publishable key (public by design, local only) in a code comment"
} > evidence/secret-scan.txt
rm -rf infra/out/site-copy
cat evidence/secret-scan.txt
echo "Done. Evidence is in evidence/."
