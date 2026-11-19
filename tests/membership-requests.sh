#!/usr/bin/env bash
# Local tests for POST /membership-api/membership-requests.
#
# Requires the local stack (npx supabase start). Run from the repository
# root in Git Bash:   bash tests/membership-requests.sh
#
# Uses only *@example.test addresses and removes them before and after.
# Keys are read from `supabase status` and never printed.

set -u

DB_CONTAINER="supabase_db_club-membership-service"
eval "$(npx supabase status -o env 2>/dev/null \
  | grep -E '^(API_URL|PUBLISHABLE_KEY|SECRET_KEY)=')"
if [ -z "${API_URL:-}" ] || [ -z "${PUBLISHABLE_KEY:-}" ]; then
  echo "Local stack is not running (npx supabase start)." >&2
  exit 2
fi

FN="$API_URL/functions/v1/membership-api"
PASS=0
FAIL=0
RUN_ID="$(date +%s)"

sql() {
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -At -c "$1"
}

cleanup() {
  sql "delete from public.membership_requests where email like '%@example.test';
       delete from public.profiles where email like '%@example.test';
       delete from auth.users where email like '%@example.test';
       delete from public.membership_request_attempts;" >/dev/null
}

# check NAME EXPECTED_STATUS ACTUAL_STATUS [BODY]
check() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-55s %s\n' "$1" "$3"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-55s expected %s, got %s  %s\n' \
      "$1" "$2" "$3" "${4:-}"
  fi
}

# post_request BODY [extra curl args...]  -> sets STATUS and BODY_OUT
post_request() {
  local data="$1"; shift
  local out
  out="$(curl -s -w '\n%{http_code}' -X POST "$FN/membership-requests" \
    -H "Content-Type: application/json" "$@" --data-binary "$data")"
  STATUS="${out##*$'\n'}"
  BODY_OUT="${out%$'\n'*}"
}

req_body() { # name email password
  printf '{"fullName":"%s","email":"%s","password":"%s"}' "$1" "$2" "$3"
}

PK=(-H "apikey: $PUBLISHABLE_KEY")
PW="CorrectHorse9"

cleanup
echo "== membership-requests tests (run $RUN_ID)"

# --- credentials
post_request "$(req_body "No Key" "nokey-$RUN_ID@example.test" "$PW")"
check "no credentials" 401 "$STATUS" "$BODY_OUT"

post_request "$(req_body "Bad Key" "badkey-$RUN_ID@example.test" "$PW")" \
  -H "apikey: sb_publishable_wrong"
check "wrong publishable key" 401 "$STATUS" "$BODY_OUT"

# --- validation (rejected before the rate limit, so they do not count)
post_request '{"fullName":"Only Name"}' "${PK[@]}"
check "missing email and password" 400 "$STATUS" "$BODY_OUT"

post_request "$(req_body "Bad Email" "not-an-email" "$PW")" "${PK[@]}"
check "bad email format" 400 "$STATUS" "$BODY_OUT"

post_request "$(req_body "Short Pw" "short-$RUN_ID@example.test" "abc123")" "${PK[@]}"
check "password shorter than 8" 400 "$STATUS" "$BODY_OUT"

post_request "$(req_body "X" "x-$RUN_ID@example.test" "$PW")" "${PK[@]}"
check "name shorter than 2" 400 "$STATUS" "$BODY_OUT"

post_request '{"fullName":' "${PK[@]}"
check "invalid JSON" 400 "$STATUS" "$BODY_OUT"

BIG="$(head -c 5000 /dev/zero | tr '\0' 'a')"
post_request "{\"fullName\":\"$BIG\"}" "${PK[@]}"
check "body over 4 KB" 413 "$STATUS" "$BODY_OUT"

STATUS="$(curl -s -o /dev/null -w '%{http_code}' "${PK[@]}" "$FN/membership-requests")"
check "GET on membership-requests" 405 "$STATUS"

# --- valid submission (rate-limit attempt 1)
EMAIL1="applicant-$RUN_ID@example.test"
post_request "$(req_body "Test Applicant" "$EMAIL1" "$PW")" "${PK[@]}"
check "valid submission" 201 "$STATUS" "$BODY_OUT"
case "$BODY_OUT" in
  *'"status":"pending"'*) check "response says pending" yes yes ;;
  *) check "response says pending" yes no "$BODY_OUT" ;;
esac

ROW="$(sql "select p.active, p.role, r.status
            from public.profiles p
            join public.membership_requests r using (user_id)
            where p.email = '$EMAIL1';")"
check "db: inactive member profile, pending request" "f|member|pending" "$ROW"

BANNED="$(sql "select banned_until > now() + interval '1 year'
               from auth.users where email = '$EMAIL1';")"
check "auth: account banned until approval" "t" "$BANNED"

# --- pending user cannot sign in directly through Auth
SIGNIN="$(curl -s -X POST \
  "$API_URL/auth/v1/token?grant_type=password" "${PK[@]}" \
  -H "Content-Type: application/json" \
  --data-binary "{\"email\":\"$EMAIL1\",\"password\":\"$PW\"}")"
case "$SIGNIN" in
  *'"error_code":"user_banned"'*) check "pending user direct Auth sign-in refused" user_banned user_banned ;;
  *) check "pending user direct Auth sign-in refused" user_banned other "$SIGNIN" ;;
esac

# --- duplicate email, different case (attempt 2)
UPPER1="$(echo "$EMAIL1" | tr '[:lower:]' '[:upper:]')"
post_request "$(req_body "Second Try" "$UPPER1" "$PW")" "${PK[@]}"
check "duplicate email (different case)" 409 "$STATUS" "$BODY_OUT"
COUNT="$(sql "select count(*) from auth.users where lower(email) = '$EMAIL1';")"
check "no extra Auth account after duplicate" "1" "$COUNT"

# --- signed-in user is refused (needs the secret key to make a test user)
if [ -n "${SECRET_KEY:-}" ]; then
  MEMBER_EMAIL="member-$RUN_ID@example.test"
  curl -s -o /dev/null -X POST "$API_URL/auth/v1/admin/users" \
    -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SECRET_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "{\"email\":\"$MEMBER_EMAIL\",\"password\":\"$PW\",\"email_confirm\":true}"
  TOKEN="$(curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" \
    "${PK[@]}" -H "Content-Type: application/json" \
    --data-binary "{\"email\":\"$MEMBER_EMAIL\",\"password\":\"$PW\"}" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
  post_request "$(req_body "Signed In" "signedin-$RUN_ID@example.test" "$PW")" \
    "${PK[@]}" -H "Authorization: Bearer $TOKEN"
  check "signed-in user token refused" 403 "$STATUS" "$BODY_OUT"
fi

# --- rate limit: attempts 3, 4, 5 succeed, 6 is refused
for i in 3 4 5; do
  post_request "$(req_body "Applicant $i" "applicant$i-$RUN_ID@example.test" "$PW")" "${PK[@]}"
  check "valid submission (attempt $i)" 201 "$STATUS" "$BODY_OUT"
done
post_request "$(req_body "Applicant 6" "applicant6-$RUN_ID@example.test" "$PW")" "${PK[@]}"
check "6th attempt in an hour" 429 "$STATUS" "$BODY_OUT"

post_request "$(req_body "Spoofer" "spoof-$RUN_ID@example.test" "$PW")" \
  "${PK[@]}" -H "X-Forwarded-For: 203.0.113.$((RUN_ID % 250))"
check "spoofed X-Forwarded-For does not reset limit" 429 "$STATUS" "$BODY_OUT"
COUNT="$(sql "select count(*) from auth.users where email like 'applicant6-%' or email like 'spoof-%';")"
check "no accounts created by refused attempts" "0" "$COUNT"

# --- direct database access with the publishable key
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "$API_URL/rest/v1/rpc/submit_membership_request" "${PK[@]}" \
  -H "Content-Type: application/json" \
  --data-binary '{"p_user_id":"00000000-0000-0000-0000-000000000000","p_full_name":"Direct","p_email":"direct@example.test"}')"
check "direct RPC submit_membership_request refused" 401 "$STATUS"

STATUS="$(curl -s -o /dev/null -w '%{http_code}' "${PK[@]}" \
  "$API_URL/rest/v1/membership_requests?select=*")"
check "direct table read refused" 401 "$STATUS"

STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "$API_URL/auth/v1/signup" "${PK[@]}" -H "Content-Type: application/json" \
  --data-binary "{\"email\":\"signup-$RUN_ID@example.test\",\"password\":\"$PW\"}")"
check "Auth /signup disabled" 422 "$STATUS"

cleanup
echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
