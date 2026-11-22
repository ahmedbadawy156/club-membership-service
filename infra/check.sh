#!/usr/bin/env bash
# Checks the deployed Membership service on Floci (evidence for the report).
#   bash infra/check.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh
[ -f infra/out/api.env ] || { echo "Run bash infra/deploy.sh first." >&2; exit 2; }
source infra/out/api.env

PASS=0; FAIL=0
check() {
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'PASS  %-55s %s\n' "$1" "$3"
  else FAIL=$((FAIL + 1)); printf 'FAIL  %-55s expected %s, got %s\n' "$1" "$2" "$3"; fi
}
status() { curl -s -o /dev/null -w '%{http_code}' -m 60 "$@"; }
header() { curl -s -D - -o /dev/null -m 60 "${@:2}" | tr -d '\r' | grep -i "^$1:" | cut -d' ' -f2; }

echo "== Membership service on Floci: $API_URL"

check "function state" "Active" \
  "$("$AWS" lambda get-function --function-name "$FUNCTION" --query Configuration.State --output text 2>&1)"
check "function runtime" "nodejs24.x" \
  "$("$AWS" lambda get-function --function-name "$FUNCTION" --query Configuration.Runtime --output text 2>&1)"

BODY=$(curl -s -m 60 "$API_URL/api/health")
check "GET /api/health through API Gateway" '{"service":"membership","status":"ok","runtime":"lambda"}' "$BODY"

check "unlisted method refused by the gateway" 404 "$(status -X DELETE "$API_URL/api/health")"
check "unknown path refused by the gateway" 404 "$(status "$API_URL/api/nothing-here")"
check "gateway refusal body" '{"message":"Not Found"}' "$(curl -s -m 60 "$API_URL/api/nothing-here")"

ALLOWED="${CORS_ORIGINS%%,*}"
check "CORS: allowed origin gets its own origin back" "$ALLOWED" \
  "$(header access-control-allow-origin -H "Origin: $ALLOWED" "$API_URL/api/health")"
check "CORS: other origin gets no header" "" \
  "$(header access-control-allow-origin -H "Origin: https://evil.example" "$API_URL/api/health")"

sleep 2
LOGLINE=$("$AWS" logs tail "$LOG_GROUP" --since 10m --format short 2>/dev/null | grep -c "GET /api/health 200" || true)
check "CloudWatch Logs has request lines" yes "$([ "${LOGLINE:-0}" -gt 0 ] && echo yes || echo no)"
check "log lines never contain a query string" 0 \
  "$("$AWS" logs tail "$LOG_GROUP" --since 10m --format short 2>/dev/null | grep -c '/api/[^ ]*?' || true)"

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
