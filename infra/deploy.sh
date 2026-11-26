#!/usr/bin/env bash
# Deploy the Membership service to Floci. Safe to run again: it creates what
# is missing and updates what exists.
#   bash infra/deploy.sh
# Steps: tables + secret -> IAM role + policy -> zip -> Lambda function -> API
# Gateway (routes, stage, permission) -> SNS topic -> notifier Lambda + its
# subscription -> EventBridge rule -> saves the API address to infra/out/api.env
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh

step() { echo "== $*"; }

"$AWS" sts get-caller-identity --query Account --output text >/dev/null 2>&1 || {
  echo "Floci is not reachable. Start it: docker compose -f infra/floci/docker-compose.yml up -d" >&2
  exit 1
}

step "0/8 DynamoDB tables and the service secret"
for def in infra/dynamodb/*.json; do
  table=$(basename "$def" .json)
  if ! "$AWS" dynamodb describe-table --table-name "$table" >/dev/null 2>&1; then
    "$AWS" dynamodb create-table --cli-input-json "file://$def" >/dev/null
    "$AWS" dynamodb wait table-exists --table-name "$table"
    echo "   + table $table"
  fi
done
for t in RateLimits MemberNotifications; do
  "$AWS" dynamodb update-time-to-live --table-name "$t" \
    --time-to-live-specification "Enabled=true,AttributeName=expiresAt" >/dev/null 2>&1 || true
done

# The secret is created once. Its values are generated into a temporary file,
# stored in Secrets Manager, and the file is deleted. Nothing is printed.
if ! "$AWS" secretsmanager describe-secret --secret-id "$SECRET_ID" >/dev/null 2>&1; then
  mkdir -p infra/out
  node infra/make-secret.js infra/out/secret.tmp.json
  "$AWS" secretsmanager create-secret --name "$SECRET_ID" \
    --description "Membership service token keys and address-hash salt" \
    --secret-string file://infra/out/secret.tmp.json >/dev/null
  rm -f infra/out/secret.tmp.json
  echo "   + secret $SECRET_ID"
fi

step "1/8 IAM role $ROLE and its policy"
if ! "$AWS" iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  "$AWS" iam create-role --role-name "$ROLE" \
    --assume-role-policy-document file://infra/iam/trust-policy.json >/dev/null
fi
"$AWS" iam put-role-policy --role-name "$ROLE" --policy-name "$ROLE_POLICY" \
  --policy-document file://infra/iam/membership-policy.json

step "2/8 Install and zip the backend"
(cd backend && npm install --omit=dev --no-audit --no-fund --loglevel=error && npm run zip --silent)

step "3/8 Lambda function $FUNCTION"
ENV_VARS="Variables={NODE_ENV=production,CORS_ORIGINS=${CORS_ORIGINS//,/\\,},SECRET_ID=$SECRET_ID,USERS_TABLE=ClubUsers,REQUESTS_TABLE=MembershipRequests,AUDIT_TABLE=AuditLog,RATE_LIMITS_TABLE=RateLimits,NOTIFICATIONS_TABLE=MemberNotifications,NOTIFICATIONS_TOPIC_ARN=$TOPIC_ARN}"
if "$AWS" lambda get-function --function-name "$FUNCTION" >/dev/null 2>&1; then
  "$AWS" lambda update-function-code --function-name "$FUNCTION" \
    --zip-file fileb://backend/lambda.zip >/dev/null
  "$AWS" lambda wait function-updated-v2 --function-name "$FUNCTION"
  "$AWS" lambda update-function-configuration --function-name "$FUNCTION" \
    --timeout 15 --memory-size 256 --environment "$ENV_VARS" >/dev/null
  "$AWS" lambda wait function-updated-v2 --function-name "$FUNCTION"
else
  "$AWS" lambda create-function --function-name "$FUNCTION" \
    --runtime nodejs24.x --handler lambda.handler \
    --role "arn:aws:iam::$ACCOUNT:role/$ROLE" \
    --zip-file fileb://backend/lambda.zip --timeout 15 --memory-size 256 \
    --environment "$ENV_VARS" >/dev/null
  "$AWS" lambda wait function-active-v2 --function-name "$FUNCTION"
fi

step "4/8 API Gateway $API_NAME"
API_ID=$("$AWS" apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId | [0]" --output text)
if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
  API_ID=$("$AWS" apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP --query ApiId --output text)
fi
FUNCTION_ARN="arn:aws:lambda:$REGION:$ACCOUNT:function:$FUNCTION"
INTEGRATION_ID=$("$AWS" apigatewayv2 get-integrations --api-id "$API_ID" \
  --query "Items[?IntegrationUri=='$FUNCTION_ARN'].IntegrationId | [0]" --output text)
if [ -z "$INTEGRATION_ID" ] || [ "$INTEGRATION_ID" = "None" ]; then
  INTEGRATION_ID=$("$AWS" apigatewayv2 create-integration --api-id "$API_ID" \
    --integration-type AWS_PROXY --payload-format-version 2.0 \
    --integration-uri "$FUNCTION_ARN" --query IntegrationId --output text)
fi

# Routes: make the gateway match infra/routes.txt exactly.
WANTED=$(grep -v '^\s*#' infra/routes.txt | sed 's/\r$//' | grep -v '^\s*$' || true)
EXISTING=$("$AWS" apigatewayv2 get-routes --api-id "$API_ID" \
  --query 'Items[].[RouteKey,RouteId]' --output text | sed 's/\r$//')
while IFS= read -r key; do
  [ -z "$key" ] && continue
  if ! printf '%s\n' "$EXISTING" | cut -f1 | grep -qxF "$key"; then
    "$AWS" apigatewayv2 create-route --api-id "$API_ID" --route-key "$key" \
      --target "integrations/$INTEGRATION_ID" >/dev/null
    echo "   + route $key"
  fi
done <<< "$WANTED"
while IFS=$'\t' read -r key id; do
  [ -z "$key" ] && continue
  if ! printf '%s\n' "$WANTED" | grep -qxF "$key"; then
    "$AWS" apigatewayv2 delete-route --api-id "$API_ID" --route-id "$id"
    echo "   - route $key (no longer listed)"
  fi
done <<< "$EXISTING"

if [ "$("$AWS" apigatewayv2 get-stages --api-id "$API_ID" --query "Items[?StageName=='\$default'] | length(@)" --output text)" = "0" ]; then
  "$AWS" apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy >/dev/null
fi

step "5/8 Allow only this API to invoke the function"
"$AWS" lambda add-permission --function-name "$FUNCTION" --statement-id apigw-invoke \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT:$API_ID/*" >/dev/null 2>&1 || true

step "6/8 SNS topic $TOPIC"
"$AWS" sns create-topic --name "$TOPIC" >/dev/null
# Who may publish: this account (the Membership role, through IAM) and the
# club bus rule below, nobody else.
RULE_ARN="arn:aws:events:$REGION:$ACCOUNT:rule/$BUS/$RULE"
TOPIC_ARN="$TOPIC_ARN" RULE_ARN="$RULE_ARN" ACCOUNT="$ACCOUNT" node -e '
const { TOPIC_ARN, RULE_ARN, ACCOUNT } = process.env;
process.stdout.write(JSON.stringify({ Version: "2012-10-17", Statement: [
  { Sid: "OwnAccount", Effect: "Allow", Principal: { AWS: "arn:aws:iam::" + ACCOUNT + ":root" },
    Action: ["sns:Publish", "sns:Subscribe", "sns:GetTopicAttributes"], Resource: TOPIC_ARN },
  { Sid: "OnlyTheClubBusRule", Effect: "Allow", Principal: { Service: "events.amazonaws.com" },
    Action: "sns:Publish", Resource: TOPIC_ARN, Condition: { ArnEquals: { "aws:SourceArn": RULE_ARN } } },
] }));' > infra/out/topic-policy.json
"$AWS" sns set-topic-attributes --topic-arn "$TOPIC_ARN" --attribute-name Policy \
  --attribute-value file://infra/out/topic-policy.json

step "7/8 Notifier function $NOTIFIER (subscribed to the topic)"
if ! "$AWS" iam get-role --role-name "$NOTIFIER_ROLE" >/dev/null 2>&1; then
  "$AWS" iam create-role --role-name "$NOTIFIER_ROLE" \
    --assume-role-policy-document file://infra/iam/trust-policy.json >/dev/null
fi
"$AWS" iam put-role-policy --role-name "$NOTIFIER_ROLE" --policy-name "$NOTIFIER_POLICY" \
  --policy-document file://infra/iam/notifier-policy.json
NOTIFIER_ENV="Variables={NODE_ENV=production,NOTIFICATIONS_TABLE=MemberNotifications}"
if "$AWS" lambda get-function --function-name "$NOTIFIER" >/dev/null 2>&1; then
  "$AWS" lambda update-function-code --function-name "$NOTIFIER" --zip-file fileb://backend/lambda.zip >/dev/null
  "$AWS" lambda wait function-updated-v2 --function-name "$NOTIFIER"
  "$AWS" lambda update-function-configuration --function-name "$NOTIFIER" \
    --timeout 15 --memory-size 256 --environment "$NOTIFIER_ENV" >/dev/null
  "$AWS" lambda wait function-updated-v2 --function-name "$NOTIFIER"
else
  "$AWS" lambda create-function --function-name "$NOTIFIER" \
    --runtime nodejs24.x --handler notifier.handler \
    --role "arn:aws:iam::$ACCOUNT:role/$NOTIFIER_ROLE" \
    --zip-file fileb://backend/lambda.zip --timeout 15 --memory-size 256 \
    --environment "$NOTIFIER_ENV" >/dev/null
  "$AWS" lambda wait function-active-v2 --function-name "$NOTIFIER"
fi
NOTIFIER_ARN="arn:aws:lambda:$REGION:$ACCOUNT:function:$NOTIFIER"
# Only this topic may invoke the notifier.
"$AWS" lambda add-permission --function-name "$NOTIFIER" --statement-id sns-invoke \
  --action lambda:InvokeFunction --principal sns.amazonaws.com --source-arn "$TOPIC_ARN" >/dev/null 2>&1 || true
SUBS=$("$AWS" sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
  --query "Subscriptions[?Endpoint=='$NOTIFIER_ARN'] | length(@)" --output text)
if [ "$SUBS" = "0" ]; then
  "$AWS" sns subscribe --topic-arn "$TOPIC_ARN" --protocol lambda --notification-endpoint "$NOTIFIER_ARN" >/dev/null
  echo "   + topic -> notifier subscription"
fi

step "8/8 EventBridge rule $RULE (bus $BUS -> topic)"
# The Events service creates the bus; create it here too if Events is not
# deployed yet, so the order of deploys does not matter.
"$AWS" events describe-event-bus --name "$BUS" >/dev/null 2>&1 || "$AWS" events create-event-bus --name "$BUS" >/dev/null
"$AWS" events put-rule --name "$RULE" --event-bus-name "$BUS" \
  --event-pattern '{"source":["club.events"],"detail-type":["EventCancelled","SeatPromoted"]}' >/dev/null
"$AWS" events put-targets --rule "$RULE" --event-bus-name "$BUS" --targets "Id=notices,Arn=$TOPIC_ARN" >/dev/null

step "Monitoring: failed-login metric and alarm"
# Every "POST /api/auth/login 401" log line counts as one FailedLogins data
# point; 5 or more in 5 minutes puts the alarm in ALARM (guessing attack).
"$AWS" logs put-metric-filter --log-group-name "$LOG_GROUP" --filter-name FailedLogins \
  --filter-pattern '"POST /api/auth/login 401"' \
  --metric-transformations metricName=FailedLogins,metricNamespace=CampusClub,metricValue=1
"$AWS" cloudwatch put-metric-alarm --alarm-name club-failed-logins-burst \
  --namespace CampusClub --metric-name FailedLogins --statistic Sum --period 300 \
  --evaluation-periods 1 --threshold 5 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching

API_URL=$(api_url "$API_ID")
mkdir -p infra/out
printf 'API_ID=%s\nAPI_URL=%s\n' "$API_ID" "$API_URL" > infra/out/api.env
echo
echo "Deployed. API: $API_URL"
echo "Try:      curl $API_URL/api/health"
