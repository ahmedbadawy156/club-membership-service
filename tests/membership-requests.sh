#!/usr/bin/env bash
# Tests for POST /api/membership-requests on the Floci deployment.
#   bash tests/membership-requests.sh        (after bash infra/deploy.sh)
# Uses only *@example.test addresses and removes them before and after.
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh
[ -f infra/out/api.env ] || { echo "Run bash infra/deploy.sh first." >&2; exit 2; }
source infra/out/api.env
source tests/lib.sh
mkdir -p infra/out/tmp

URL="$API_URL/api/membership-requests"
PW="CorrectHorse9"
RUN_ID=$(date +%s)

post() { # BODY [extra curl args] -> STATUS, BODY_OUT, HEADERS
  local data="$1"; shift
  local tmp="infra/out/tmp/post.$$"
  STATUS=$(curl -s -m 60 -D "$tmp.h" -o "$tmp" -w '%{http_code}' -X POST "$URL" \
    -H "Content-Type: application/json" "$@" --data-binary "$data")
  BODY_OUT=$(cat "$tmp"); HEADERS=$(tr -d '\r' < "$tmp.h"); rm -f "$tmp" "$tmp.h"
}
req_json() { printf '{"fullName":"%s","email":"%s","password":"%s"}' "$1" "$2" "$3"; }

cleanup_test_data
echo "== membership-requests tests on $API_URL (run $RUN_ID)"

# --- valid request
E1="applicant-$RUN_ID@example.test"
post "$(req_json "Test Applicant" "$E1" "$PW")"
check "valid request" 201 "$STATUS" "$BODY_OUT"
check "  response has only requestId and status" "requestId,status" \
  "$(printf '%s' "$BODY_OUT" | jq_keys)"
REQ_ID=$(printf '%s' "$BODY_OUT" | jget 'j.requestId')

ITEM=$("$AWS" dynamodb get-item --table-name MembershipRequests --key "{\"requestId\":{\"S\":\"$REQ_ID\"}}" --output json)
check "  stored as pending" pending "$(printf '%s' "$ITEM" | jget 'j.Item.status.S')"
HASH=$(printf '%s' "$ITEM" | jget 'j.Item.passwordHash.S')
check "  password stored as a bcrypt hash" yes "$(case "$HASH" in '$2'*) echo yes;; *) echo no;; esac)"
check "  plain password not stored anywhere in the item" no \
  "$(printf '%s' "$ITEM" | grep -q "$PW" && echo yes || echo no)"
check "  address stored only as a 64-char hash" yes \
  "$(printf '%s' "$ITEM" | jget 'j.Item.sourceIpHash.S' | grep -Eq '^[0-9a-f]{64}$' && echo yes || echo no)"
check "  email claimed once (EMAIL# item)" "$REQ_ID" \
  "$("$AWS" dynamodb get-item --table-name MembershipRequests --key "{\"requestId\":{\"S\":\"EMAIL#$E1\"}}" --query 'Item.claimFor.S' --output text)"
check "  no account created before approval" 0 \
  "$("$AWS" dynamodb scan --table-name ClubUsers --filter-expression 'emailLower = :e' --expression-attribute-values "{\":e\":{\"S\":\"$E1\"}}" --query Count --output text)"

# --- duplicate email, different case
post "$(req_json "Second Try" "$(echo "$E1" | tr '[:lower:]' '[:upper:]')" "$PW")"
check "duplicate email (different case)" 409 "$STATUS" "$BODY_OUT"
check "  still exactly one request for the email" 1 \
  "$("$AWS" dynamodb scan --table-name MembershipRequests --filter-expression 'emailLower = :e' --expression-attribute-values "{\":e\":{\"S\":\"$E1\"}}" --query Count --output text)"

# --- script text is stored as plain text
E2="script-$RUN_ID@example.test"
post "$(req_json 'Name <script>alert(1)</script>' "$E2" "$PW")"
check "name with script text accepted as text" 201 "$STATUS" "$BODY_OUT"
check "  stored exactly as typed" 'Name <script>alert(1)</script>' \
  "$("$AWS" dynamodb scan --table-name MembershipRequests --filter-expression 'emailLower = :e' --expression-attribute-values "{\":e\":{\"S\":\"$E2\"}}" --query 'Items[0].fullName.S' --output text)"

reset_rate_limits

# --- validation (refused before the rate limit, so they do not count)
post '{"fullName":"Only Name"}';                   check "missing email and password" 400 "$STATUS" "$BODY_OUT"
check "  names the fields" "email,password" "$(printf '%s' "$BODY_OUT" | jget 'j.fields.join(",")')"
post "$(req_json "Bad Email" "not-an-email" "$PW")"; check "bad email format" 400 "$STATUS"
post "$(req_json "Short Pw" "s-$RUN_ID@example.test" "abc1234")"; check "password shorter than 8" 400 "$STATUS"
post "$(req_json "X" "x-$RUN_ID@example.test" "$PW")"; check "name shorter than 2" 400 "$STATUS"
post "$(req_json "Long Pw" "l-$RUN_ID@example.test" "$(head -c 73 /dev/zero | tr '\0' 'a')")"; check "password over 72 bytes" 400 "$STATUS"
post '["not","an","object"]';                      check "array instead of object" 400 "$STATUS"
post '{"fullName":';                               check "invalid JSON" 400 "$STATUS" "$BODY_OUT"
post "{\"fullName\":\"$(head -c 5000 /dev/zero | tr '\0' 'a')\"}"; check "body over 4 KB" 413 "$STATUS" "$BODY_OUT"
post "$(req_json "Signed In" "si-$RUN_ID@example.test" "$PW")" -H "Authorization: Bearer x.y.z"
check "caller with a token refused" 403 "$STATUS" "$BODY_OUT"

# --- gateway route allow-list
check "PUT not listed: refused by the gateway" '{"message":"Not Found"} 404' \
  "$(curl -s -m 60 -w ' %{http_code}' -X PUT "$URL")"

# --- CORS preflight
ORIGIN="${CORS_ORIGINS%%,*}"
pre() { curl -s -m 60 -D - -o /dev/null -X OPTIONS "$URL" -H "Origin: $1" \
  -H "Access-Control-Request-Method: POST" -H "Access-Control-Request-Headers: content-type" | tr -d '\r'; }
check "preflight from the website origin" "$ORIGIN" "$(pre "$ORIGIN" | grep -i '^access-control-allow-origin:' | cut -d' ' -f2)"
check "preflight from another origin: no allow header" "" "$(pre https://evil.example | grep -i '^access-control-allow-origin:' | cut -d' ' -f2)"

# --- simultaneous requests for one email: exactly one wins
E3="race-$RUN_ID@example.test"
TMPD=infra/out/tmp/race.$$; mkdir -p "$TMPD"
for i in 1 2 3 4; do
  ( curl -s -m 60 -o /dev/null -w '%{http_code}' -X POST "$URL" -H "Content-Type: application/json" \
      --data-binary "$(req_json "Racer $i" "$E3" "$PW")" > "$TMPD/$i" ) &
done
wait
check "4 simultaneous requests, same email" "201x1 409x3" \
  "$(for f in "$TMPD"/*; do cat "$f"; echo; done | sort | uniq -c | awk '{print $2"x"$1}' | paste -sd' ')"
rm -rf "$TMPD"

reset_rate_limits

# --- rate limit: 5 per hour per address, then 429
CODES=""
for i in 1 2 3 4 5; do post "$(req_json "Limit $i" "limit$i-$RUN_ID@example.test" "$PW")"; CODES="$CODES$STATUS "; done
check "5 requests from one address" "201 201 201 201 201 " "$CODES"
post "$(req_json "Limit 6" "limit6-$RUN_ID@example.test" "$PW")"
check "6th request in the hour" 429 "$STATUS" "$BODY_OUT"
check "  has a Retry-After header" yes \
  "$(printf '%s\n' "$HEADERS" | grep -qi '^retry-after: [0-9]' && echo yes || echo no)"
post "$(req_json "Spoofer" "spoof-$RUN_ID@example.test" "$PW")" -H "X-Forwarded-For: 203.0.113.9"
check "spoofed X-Forwarded-For does not reset the limit" 429 "$STATUS"
check "  refused requests stored nothing" 0 \
  "$("$AWS" dynamodb scan --table-name MembershipRequests --filter-expression 'emailLower IN (:a, :b)' --expression-attribute-values "{\":a\":{\"S\":\"limit6-$RUN_ID@example.test\"},\":b\":{\"S\":\"spoof-$RUN_ID@example.test\"}}" --query Count --output text)"

cleanup_test_data
finish
