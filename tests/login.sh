#!/usr/bin/env bash
# Tests for POST /api/auth/login and GET /api/auth/public-key on Floci:
# lockout, limits, identical failures, token contents.
#   bash tests/login.sh        (after bash infra/deploy.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh
[ -f infra/out/api.env ] || { echo "Run bash infra/deploy.sh first." >&2; exit 2; }
source infra/out/api.env
source tests/lib.sh
mkdir -p infra/out/tmp

LOGIN="$API_URL/api/auth/login"
PW="CorrectHorse9"
RUN_ID=$(date +%s)

login() { # EMAIL PASSWORD [extra curl args] -> STATUS, BODY_OUT, HEADERS
  local e="$1" p="$2"; shift 2
  local tmp="infra/out/tmp/login.$$"
  STATUS=$(curl -s -m 60 -D "$tmp.h" -o "$tmp" -w '%{http_code}' -X POST "$LOGIN" \
    -H "Content-Type: application/json" "$@" --data-binary "{\"email\":\"$e\",\"password\":\"$p\"}")
  BODY_OUT=$(cat "$tmp"); HEADERS=$(tr -d '\r' < "$tmp.h"); rm -f "$tmp" "$tmp.h"
}
token_of() { login "$1" "$2"; printf '%s' "$BODY_OUT" | jget 'j.accessToken'; }
user_item() { # EMAIL -> JSON
  "$AWS" dynamodb query --table-name ClubUsers --index-name EmailIndex \
    --key-condition-expression 'emailLower = :e' --expression-attribute-values "{\":e\":{\"S\":\"$1\"}}" \
    --query 'Items[0]' --output json
}
counter() { user_item "$1" | jget 'j.failedLogins.N'; }
submit() { curl -s -m 60 -X POST "$API_URL/api/membership-requests" -H "Content-Type: application/json" \
  --data-binary "{\"fullName\":\"$1\",\"email\":\"$2\",\"password\":\"$PW\"}" | jget 'j.requestId'; }
approve() { curl -s -m 60 -o /dev/null -w '%{http_code}' -X PATCH "$API_URL/api/membership-requests/$1" \
  -H "Authorization: Bearer $2" -H "Content-Type: application/json" --data-binary '{"decision":"approve"}'; }

cleanup_test_data
echo "== login tests on $API_URL (run $RUN_ID)"

# --- setup: an officer signs in through the API and approves three members
E_OFF="officer-$RUN_ID@example.test"
OFFICER_ID=$(helper make-officer "Test Officer" "$E_OFF" "$PW")
T_OFF=$(token_of "$E_OFF" "$PW")
check "officer signs in through the API" yes "$([ -n "$T_OFF" ] && echo yes || echo no)"
E_M="member-$RUN_ID@example.test"; E_L="locked-$RUN_ID@example.test"; E_B="burst-$RUN_ID@example.test"; E_P="pending-$RUN_ID@example.test"
for e in "$E_M" "$E_L" "$E_B"; do approve "$(submit "Member ${e%%-*}" "$e")" "$T_OFF" >/dev/null; done
submit "Pending P" "$E_P" >/dev/null
check "setup: three approved members exist" "member|member|member" \
  "$(user_item "$E_M" | jget 'j.role.S')|$(user_item "$E_L" | jget 'j.role.S')|$(user_item "$E_B" | jget 'j.role.S')"
reset_rate_limits

# --- successful login
login "$E_M" "$PW"
check "correct login" 200 "$STATUS" "$BODY_OUT"
check "  response fields" "accessToken,expiresAt,expiresIn,tokenType,user" "$(printf '%s' "$BODY_OUT" | jq_keys)"
check "  user and expiry" "member|Bearer|900" "$(printf '%s' "$BODY_OUT" | jget 'j.user.role+"|"+j.tokenType+"|"+j.expiresIn')"
TOKEN=$(printf '%s' "$BODY_OUT" | jget 'j.accessToken')
PUB=$(curl -s -m 60 "$API_URL/api/auth/public-key")
check "public key endpoint" "RS256|club-membership|campus-club|yes" \
  "$(printf '%s' "$PUB" | jget 'j.algorithm+"|"+j.issuer+"|"+j.audience+"|"+(j.publicKey.includes("BEGIN PUBLIC KEY")?"yes":"no")')"
check "  never contains a private key" no "$(printf '%s' "$PUB" | grep -q PRIVATE && echo yes || echo no)"
VERIFY=$(printf '%s' "$PUB" | node -e '
  const jwt=require("./backend/node_modules/jsonwebtoken");let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try{const k=JSON.parse(s).publicKey;const c=jwt.verify(process.argv[1],k,{algorithms:["RS256"],issuer:"club-membership",audience:"campus-club"});
  console.log([c.role, c.exp-c.iat, c.sub.length].join("|"))}catch(e){console.log("FAIL "+e.message)}})' "$TOKEN")
check "  token verifies with the published key (role|lifetime|sub)" "member|900|36" "$VERIFY"
check "  counter reset to 0" 0 "$(counter "$E_M")"

# --- identical 401 for wrong password, unknown email, pending applicant
login "$E_M" "WrongHorse9";              S1=$STATUS; B1=$BODY_OUT
check "  counter after one wrong password" 1 "$(counter "$E_M")"
login "nobody-$RUN_ID@example.test" "$PW"; S2=$STATUS; B2=$BODY_OUT
login "$E_P" "$PW";                       S3=$STATUS; B3=$BODY_OUT
check "wrong password / unknown email / pending applicant" "401 401 401" "$S1 $S2 $S3"
check "  identical bodies" '{"error":"invalid_credentials"}' "$([ "$B1" = "$B2" ] && [ "$B2" = "$B3" ] && echo "$B1" || echo "$B1 | $B2 | $B3")"
login "$E_M" "$PW"
check "success after a failure resets the counter" "200|0" "$STATUS|$(counter "$E_M")"

# --- lockout
reset_rate_limits
L_ID=$(user_item "$E_L" | jget 'j.userId.S')
CODES=""; for _ in 1 2 3 4 5; do login "$E_L" "WrongHorse9"; CODES="$CODES$STATUS "; done
check "five wrong passwords" "401 401 401 401 401 " "$CODES"
login "$E_L" "$PW"
check "6th attempt with the CORRECT password" 423 "$STATUS" "$BODY_OUT"
RA=$(printf '%s\n' "$HEADERS" | grep -i '^retry-after:' | awk '{print $2}')
check "  Retry-After between 1 and 900" yes "$([ -n "$RA" ] && [ "$RA" -ge 1 ] && [ "$RA" -le 900 ] && echo yes || echo no)" "$RA"
AUD=$("$AWS" dynamodb scan --table-name AuditLog --output json)
check "audit: 5 login_failure + 1 account_locked" "5|1" \
  "$(printf '%s' "$AUD" | jget "j.Items.filter(e=>e.targetId?.S==='$L_ID'&&e.eventType.S==='login_failure').length")|$(printf '%s' "$AUD" | jget "j.Items.filter(e=>e.targetId?.S==='$L_ID'&&e.eventType.S==='account_locked').length")"
check "  audit entries contain no email or address" 0 \
  "$(printf '%s' "$AUD" | jget "j.Items.filter(e=>e.targetId?.S==='$L_ID').filter(e=>/@|sourceIp|ip/i.test(JSON.stringify(e.metadata||{}))).length")"

# lock expires (simulated): move the lock into the past
helper set-user "$L_ID" lockedUntil "$(( $(date +%s) - 1 ))"
login "$E_L" "$PW"
check "login works after the lock expires" 200 "$STATUS" "$BODY_OUT"
check "  counter reset, lock removed" "0|" "$(counter "$E_L")|$(user_item "$E_L" | jget 'j.lockedUntil?.N')"

# --- 10 wrong passwords at the same moment
reset_rate_limits
B_ID=$(user_item "$E_B" | jget 'j.userId.S')
TMPD=infra/out/tmp/burst.$$; mkdir -p "$TMPD"
for i in $(seq 1 10); do
  ( curl -s -m 60 -o /dev/null -w '%{http_code}' -X POST "$LOGIN" -H "Content-Type: application/json" \
      --data-binary "{\"email\":\"$E_B\",\"password\":\"WrongHorse9\"}" > "$TMPD/$i" ) &
done
wait
check "10 simultaneous wrong logins: 5 checked, 5 refused" "401x5 423x5" \
  "$(for f in "$TMPD"/*; do cat "$f"; echo; done | sort | uniq -c | awk '{print $2"x"$1}' | paste -sd' ')"
rm -rf "$TMPD"
check "  locked, exactly one account_locked entry" "yes|1" \
  "$([ -n "$(user_item "$E_B" | jget 'j.lockedUntil?.N')" ] && echo yes || echo no)|$("$AWS" dynamodb scan --table-name AuditLog --output json | jget "j.Items.filter(e=>e.targetId?.S==='$B_ID'&&e.eventType.S==='account_locked').length")"

# --- deactivated account
helper set-user "$(user_item "$E_M" | jget 'j.userId.S')" active false
login "$E_M" "$PW"; check "deactivated account, correct password" "401|$B1" "$STATUS|$BODY_OUT"
helper set-user "$(user_item "$E_M" | jget 'j.userId.S')" active true

# --- per-address limit: fill this address's window up to 20, the next is 429
reset_rate_limits
login "nobody-$RUN_ID@example.test" "$PW"
KEY=$("$AWS" dynamodb scan --table-name RateLimits --filter-expression 'begins_with(limitKey, :l)' \
  --expression-attribute-values '{":l":{"S":"login#"}}' --query 'Items[0].limitKey.S' --output text)
"$AWS" dynamodb update-item --table-name RateLimits --key "{\"limitKey\":{\"S\":\"$KEY\"}}" \
  --update-expression 'SET hits = :n' --expression-attribute-values '{":n":{"N":"20"}}' >/dev/null
BEFORE=$(counter "$E_M")
login "$E_M" "$PW"
check "21st attempt from one address in 15 minutes" 429 "$STATUS" "$BODY_OUT"
check "  counter of the account not touched" "$BEFORE" "$(counter "$E_M")"
reset_rate_limits

# --- input and caller checks
login "not-an-email" "$PW";                        check "invalid email" 400 "$STATUS" "$BODY_OUT"
login "$E_M" "";                                   check "empty password" 400 "$STATUS" "$BODY_OUT"
login "$E_M" "$PW" -H "Authorization: Bearer $TOKEN"; check "caller already signed in" 403 "$STATUS" "$BODY_OUT"
check "GET on login: refused by the gateway" 404 "$(curl -s -m 60 -o /dev/null -w '%{http_code}' "$LOGIN")"

cleanup_test_data
finish
