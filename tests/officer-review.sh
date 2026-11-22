#!/usr/bin/env bash
# Tests for officer review on the Floci deployment:
#   GET   /api/membership-requests?status=
#   PATCH /api/membership-requests/{id}
# plus token checks and infra/create-officer.sh.
#   bash tests/officer-review.sh        (after bash infra/deploy.sh)
# Officer and member tokens come from the real login; tests/helpers.js mints
# only the attack tokens (stale role, expired, wrong key, alg none, HS256).
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

call() { # METHOD PATH TOKEN [BODY] -> STATUS, BODY_OUT
  local m="$1" p="$2" t="$3" b="${4:-}" tmp="infra/out/tmp/call.$$"
  local args=(-s -m 60 -o "$tmp" -w '%{http_code}' -X "$m" "$URL$p")
  [ -n "$t" ] && args+=(-H "Authorization: Bearer $t")
  [ -n "$b" ] && args+=(-H "Content-Type: application/json" --data-binary "$b")
  STATUS=$(curl "${args[@]}"); BODY_OUT=$(cat "$tmp"); rm -f "$tmp"
}
submit() { # NAME EMAIL -> requestId
  curl -s -m 60 -X POST "$URL" -H "Content-Type: application/json" \
    --data-binary "{\"fullName\":\"$1\",\"email\":\"$2\",\"password\":\"$PW\"}" | jget 'j.requestId'
}
signin() { # EMAIL -> access token from the real login
  curl -s -m 60 -X POST "$API_URL/api/auth/login" -H "Content-Type: application/json" \
    --data-binary "{\"email\":\"$1\",\"password\":\"$PW\"}" | jget 'j.accessToken'
}
user_by_email() { # EMAIL -> JSON item or ""
  "$AWS" dynamodb query --table-name ClubUsers --index-name EmailIndex \
    --key-condition-expression 'emailLower = :e' --expression-attribute-values "{\":e\":{\"S\":\"$1\"}}" \
    --query 'Items[0]' --output json
}
audit_count() { # FILTER_JSON_EXPR (j = list of items) -> number
  "$AWS" dynamodb scan --table-name AuditLog --output json | jget "j.Items.filter(e => $1).length"
}

cleanup_test_data
echo "== officer review tests on $API_URL (run $RUN_ID)"

# --- create-officer.sh: success only when the club has no officer yet
OFFICERS=$("$AWS" dynamodb get-item --table-name ClubUsers --key '{"userId":{"S":"META#officers"}}' --query 'Item.count.N' --output text)
if [ "$OFFICERS" = "0" ] || [ "$OFFICERS" = "None" ]; then
  OUT=$(OFFICER_NAME="Script Officer" OFFICER_EMAIL="scriptofficer-$RUN_ID@example.test" OFFICER_PASSWORD="$PW" bash infra/create-officer.sh 2>&1)
  check "create-officer.sh creates the first officer" yes "$(echo "$OUT" | grep -q 'Officer created' && echo yes || echo no)" "$OUT"
  check "  officer stored as active officer" "officer|true" \
    "$(user_by_email "scriptofficer-$RUN_ID@example.test" | jget 'j.role.S + "|" + j.active.BOOL')"
  check "  bootstrap audit entry written" 1 "$(audit_count "e.metadata?.M?.reason?.S === 'bootstrap' && e.targetId?.S === '$(user_by_email "scriptofficer-$RUN_ID@example.test" | jget 'j.userId.S')'")"
else
  echo "SKIP  create-officer success path (a real officer already exists)"
fi

OFFICER_ID=$(helper make-officer "Test Officer" "officer-$RUN_ID@example.test" "$PW")
T_OFF=$(signin "officer-$RUN_ID@example.test")
check "officer token from the real login" yes "$([ -n "$T_OFF" ] && echo yes || echo no)"

OUT=$(OFFICER_NAME="Second Officer" OFFICER_EMAIL="second-$RUN_ID@example.test" OFFICER_PASSWORD="$PW" bash infra/create-officer.sh 2>&1)
check "create-officer.sh refused when an officer exists" yes "$(echo "$OUT" | grep -q 'already exists' && echo yes || echo no)" "$OUT"
check "  and created nothing" "" "$(user_by_email "second-$RUN_ID@example.test" | jget 'j.userId.S')"

# --- applicants
EA="appa-$RUN_ID@example.test"; EB="appb-$RUN_ID@example.test"; EC="appc-$RUN_ID@example.test"; ED="appd-$RUN_ID@example.test"
REQ_A=$(submit "Applicant A" "$EA"); REQ_B=$(submit "Applicant B" "$EB")
REQ_C=$(submit "Applicant C" "$EC"); REQ_D=$(submit "Applicant D" "$ED")
check "setup: four requests submitted" yes "$([ -n "$REQ_A$REQ_B$REQ_C$REQ_D" ] && [ ${#REQ_D} -eq 36 ] && echo yes || echo no)"
reset_rate_limits

# --- list
call GET "" "$T_OFF"
check "officer lists pending requests" 200 "$STATUS" "$BODY_OUT"
check "  contains the four test requests, oldest first" "$REQ_A,$REQ_B,$REQ_C,$REQ_D" \
  "$(printf '%s' "$BODY_OUT" | jget "j.requests.filter(r=>r.email.endsWith('-$RUN_ID@example.test')).map(r=>r.requestId).join(',')")"
check "  only documented fields, no hash" "email,fullName,requestId,reviewedAt,reviewedBy,status,submittedAt" \
  "$(printf '%s' "$BODY_OUT" | jget 'Object.keys(j.requests[0]).sort().join(",")')"
call GET "?status=bogus" "$T_OFF"; check "invalid status filter" 400 "$STATUS" "$BODY_OUT"

# --- approve A
call PATCH "/$REQ_A" "$T_OFF" '{"decision":"approve"}'
check "approve request A" 200 "$STATUS" "$BODY_OUT"
check "  response" "$REQ_A|approved|false" "$(printf '%s' "$BODY_OUT" | jget 'j.requestId+"|"+j.status+"|"+j.alreadyDecided')"
UA=$(user_by_email "$EA")
check "  account created: active member" "member|true|0" "$(printf '%s' "$UA" | jget 'j.role.S+"|"+j.active.BOOL+"|"+j.failedLogins.N')"
check "  password hash moved to the account" yes "$(printf '%s' "$UA" | jget 'j.passwordHash.S' | grep -q '^\$2' && echo yes || echo no)"
RA=$("$AWS" dynamodb get-item --table-name MembershipRequests --key "{\"requestId\":{\"S\":\"$REQ_A\"}}" --output json)
check "  request: approved, reviewer recorded, no hash left" "approved|$OFFICER_ID|" \
  "$(printf '%s' "$RA" | jget '(j.Item.status.S)+"|"+(j.Item.reviewedBy.S)+"|"+(j.Item.passwordHash ? "HASH" : "")')"
UA_ID=$(printf '%s' "$UA" | jget 'j.userId.S')
check "  audit: membership_approved by the officer" 1 \
  "$(audit_count "e.eventType.S==='membership_approved' && e.actorId?.S==='$OFFICER_ID' && e.targetId?.S==='$UA_ID'")"

call PATCH "/$REQ_A" "$T_OFF" '{"decision":"approve"}'
check "approve A again" "200|true" "$STATUS|$(printf '%s' "$BODY_OUT" | jget 'j.alreadyDecided')"
check "  no second account, no second audit entry" "1|1" \
  "$("$AWS" dynamodb scan --table-name ClubUsers --filter-expression 'emailLower = :e' --expression-attribute-values "{\":e\":{\"S\":\"$EA\"}}" --query Count --output text)|$(audit_count "e.eventType.S==='membership_approved' && e.targetId?.S==='$UA_ID'")"
call PATCH "/$REQ_A" "$T_OFF" '{"decision":"reject"}'
check "reject A after approval" 409 "$STATUS" "$BODY_OUT"

# --- reject B
call PATCH "/$REQ_B" "$T_OFF" '{"decision":"reject"}'
check "reject request B" 200 "$STATUS" "$BODY_OUT"
check "  no account for B, hash removed from request" "|" \
  "$(user_by_email "$EB" | jget 'j.userId.S')|$("$AWS" dynamodb get-item --table-name MembershipRequests --key "{\"requestId\":{\"S\":\"$REQ_B\"}}" --query 'Item.passwordHash.S' --output text | sed 's/None//')"
check "  audit: membership_rejected with applicant name, no email" "1|" \
  "$(audit_count "e.eventType.S==='membership_rejected' && e.metadata?.M?.requestId?.S==='$REQ_B'")|$("$AWS" dynamodb scan --table-name AuditLog --output json | grep -c "$EB" | sed 's/^0$//')"
check "B cannot apply again with the same email" 409 \
  "$(curl -s -m 60 -o /dev/null -w '%{http_code}' -X POST "$URL" -H 'Content-Type: application/json' --data-binary "{\"fullName\":\"Again\",\"email\":\"$EB\",\"password\":\"$PW\"}")"
reset_rate_limits

# --- approve and reject the same request at the same moment
TMPD=infra/out/tmp/race.$$; mkdir -p "$TMPD"
( curl -s -m 60 -o /dev/null -w '%{http_code}' -X PATCH "$URL/$REQ_C" -H "Authorization: Bearer $T_OFF" -H 'Content-Type: application/json' --data-binary '{"decision":"approve"}' > "$TMPD/a" ) &
( curl -s -m 60 -o /dev/null -w '%{http_code}' -X PATCH "$URL/$REQ_C" -H "Authorization: Bearer $T_OFF" -H 'Content-Type: application/json' --data-binary '{"decision":"reject"}' > "$TMPD/r" ) &
wait
check "approve + reject at once: one wins" "200 409" "$(printf '%s\n%s\n' "$(cat "$TMPD/a")" "$(cat "$TMPD/r")" | sort | paste -sd' ')"
FINAL=$("$AWS" dynamodb get-item --table-name MembershipRequests --key "{\"requestId\":{\"S\":\"$REQ_C\"}}" --query 'Item.status.S' --output text)
check "  account exists only if approved" "$FINAL" \
  "$([ -n "$(user_by_email "$EC" | jget 'j.userId.S')" ] && echo approved || echo rejected)"
rm -rf "$TMPD"

# --- callers who must be refused
T_MEM=$(signin "$EA")
check "approved member signs in" yes "$([ -n "$T_MEM" ] && echo yes || echo no)"
call GET "" "$T_MEM";                                   check "member token: list" 403 "$STATUS" "$BODY_OUT"
call PATCH "/$REQ_D" "$T_MEM" '{"decision":"approve"}'; check "member token: approve" 403 "$STATUS" "$BODY_OUT"
T_STALE=$(helper token "$UA_ID" officer)
call GET "" "$T_STALE"; check "token says officer but database says member" 403 "$STATUS" "$BODY_OUT"
call GET "" "";         check "no token" 401 "$STATUS" "$BODY_OUT"
call GET "" "not-a-token"; check "malformed token" 401 "$STATUS" "$BODY_OUT"
for v in expired wrongkey none hs256; do
  call GET "" "$(helper token "$OFFICER_ID" officer $v)"
  check "officer token with $v signature/expiry" 401 "$STATUS" "$BODY_OUT"
done
check "request D still pending after refused attempts" pending \
  "$("$AWS" dynamodb get-item --table-name MembershipRequests --key "{\"requestId\":{\"S\":\"$REQ_D\"}}" --query 'Item.status.S' --output text)"

# --- deactivated officer loses access at once
helper set-user "$OFFICER_ID" active false
call GET "" "$T_OFF";                                   check "deactivated officer: list" 403 "$STATUS" "$BODY_OUT"
call PATCH "/$REQ_D" "$T_OFF" '{"decision":"approve"}'; check "deactivated officer: approve" 403 "$STATUS" "$BODY_OUT"
helper set-user "$OFFICER_ID" active true

# --- input errors and route list
call PATCH "/not-a-uuid" "$T_OFF" '{"decision":"approve"}';                         check "invalid request id" 400 "$STATUS" "$BODY_OUT"
call PATCH "/00000000-0000-4000-8000-000000000000" "$T_OFF" '{"decision":"approve"}'; check "unknown request id" 404 "$STATUS" "$BODY_OUT"
call PATCH "/$REQ_D" "$T_OFF" '{"decision":"maybe"}';                               check "invalid decision" 400 "$STATUS" "$BODY_OUT"
call GET "/$REQ_D" "$T_OFF"; check "GET on a single request: refused by the gateway" 404 "$STATUS" "$BODY_OUT"

# --- approved list
call GET "?status=approved" "$T_OFF"
check "approved list shows A reviewed by the officer" "$OFFICER_ID" \
  "$(printf '%s' "$BODY_OUT" | jget "(j.requests.find(r=>r.requestId==='$REQ_A')||{}).reviewedBy")"

cleanup_test_data
finish
