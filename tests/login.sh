#!/usr/bin/env bash
# Local tests for POST /membership-api/auth/login (lockout, limits, responses).
#
# Requires the local stack (npx supabase start). Run from the repository
# root in Git Bash:   bash tests/login.sh
#
# Creates its own users with *@example.test addresses and removes them
# before and after. Keys and tokens are never printed.
#
# Note: this script makes about 20 sign-in calls to Auth. Auth's local
# sign-in limit is shared by every caller (all requests reach Auth through
# the gateway), so running several test scripts back to back may hit it;
# if a check reports 503 try_again_later, wait five minutes.

set -u

DB_CONTAINER="supabase_db_club-membership-service"
eval "$(npx supabase status -o env 2>/dev/null \
  | grep -E '^(API_URL|PUBLISHABLE_KEY|SECRET_KEY)=')"
if [ -z "${API_URL:-}" ] || [ -z "${PUBLISHABLE_KEY:-}" ] || [ -z "${SECRET_KEY:-}" ]; then
  echo "Local stack is not running (npx supabase start)." >&2
  exit 2
fi

FN="$API_URL/functions/v1/membership-api"
PW="CorrectHorse9"
RUN_ID="$(date +%s)"
SUFFIX="-$RUN_ID@example.test"
PASS=0
FAIL=0
PK=(-H "apikey: $PUBLISHABLE_KEY")
SK=(-H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SECRET_KEY")
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

sql() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -At -c "$1"; }

cleanup() {
  sql "delete from public.audit_log
         where target_id in (select id from auth.users where email like '%@example.test')
            or actor_id in (select id from auth.users where email like '%@example.test');
       delete from public.membership_requests where email like '%@example.test';
       delete from public.profiles where email like '%@example.test';
       delete from auth.users where email like '%@example.test';
       delete from public.membership_request_attempts;
       delete from public.login_attempts;" >/dev/null
}

check() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-55s %s\n' "$1" "$3"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-55s expected %s, got %s  %s\n' \
      "$1" "$2" "$3" "${4:-}"
  fi
}

jget() {
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    let j;try{j=JSON.parse(s)}catch{j=null}
    let v;try{v=eval(process.argv[1])}catch{v=undefined}
    process.stdout.write(v===undefined||v===null?"":String(v))})' "$1"
}

claim() {
  node -e 'try{const p=JSON.parse(Buffer.from(process.argv[1].split(".")[1],"base64url"));
    const v=eval(process.argv[2]);console.log(v==null?"":v)}catch{console.log("")}' "$1" "$2"
}

make_user() { # NAME EMAIL -> user id (active member)
  local id
  id="$(curl -s -X POST "$API_URL/auth/v1/admin/users" "${SK[@]}" \
    -H "Content-Type: application/json" \
    --data-binary "{\"email\":\"$2\",\"password\":\"$PW\",\"email_confirm\":true,\"app_metadata\":{\"role\":\"member\"}}" \
    | jget 'j.id')"
  sql "insert into public.profiles (user_id, full_name, email, role, active)
       values ('$id', '$1', '$2', 'member', true);" >/dev/null
  printf '%s' "$id"
}

# login EMAIL PASSWORD [extra curl args] -> sets STATUS, BODY, HEADERS
login() {
  local email="$1" password="$2"; shift 2
  curl -s -D "$TMP/h" -o "$TMP/b" -w '%{http_code}' -X POST "$FN/auth/login" \
    "${PK[@]}" -H "Content-Type: application/json" "$@" \
    --data-binary "{\"email\":\"$email\",\"password\":\"$password\"}" > "$TMP/s"
  STATUS="$(cat "$TMP/s")"; BODY="$(cat "$TMP/b")"; HEADERS="$(tr -d '\r' < "$TMP/h")"
}

counter() { sql "select failed_login_count from public.profiles where email = '$1';"; }
reset_ip_limit() { sql "delete from public.login_attempts;" >/dev/null; }

cleanup
echo "== login tests (run $RUN_ID)"

E_M="member$SUFFIX"; E_L="locked$SUFFIX"; E_B="burst$SUFFIX"; E_P="pending$SUFFIX"
ID_M="$(make_user "Member M" "$E_M")"
ID_L="$(make_user "Locked L" "$E_L")"
ID_B="$(make_user "Burst B" "$E_B")"
curl -s -o /dev/null -X POST "$FN/membership-requests" "${PK[@]}" \
  -H "Content-Type: application/json" \
  --data-binary "{\"fullName\":\"Pending P\",\"email\":\"$E_P\",\"password\":\"$PW\"}"

# --- successful login
login "$E_M" "$PW"
check "correct login" 200 "$STATUS" "$BODY"
TOKEN="$(printf '%s' "$BODY" | jget 'j.accessToken')"
check "  response user and expiry" "Member M|member|900" \
  "$(printf '%s' "$BODY" | jget 'j.user.fullName+"|"+j.user.role+"|"+j.expiresIn')"
check "  refresh token returned" yes \
  "$([ -n "$(printf '%s' "$BODY" | jget 'j.refreshToken')" ] && echo yes || echo no)"
check "  token role claim" member "$(claim "$TOKEN" 'p.app_metadata.role')"
check "  counter reset to 0" 0 "$(counter "$E_M")"

# --- identical 401 for wrong password, unknown email, pending applicant
login "$E_M" "WrongHorse9";            S1="$STATUS"; B1="$BODY"
check "  counter after one wrong password" 1 "$(counter "$E_M")"
login "nobody$SUFFIX" "$PW";            S2="$STATUS"; B2="$BODY"
login "$E_P" "$PW";                     S3="$STATUS"; B3="$BODY"
check "wrong password / unknown email / pending" "401 401 401" "$S1 $S2 $S3"
check "  identical bodies" yes \
  "$([ "$B1" = "$B2" ] && [ "$B2" = "$B3" ] && echo yes || echo no)" "$B1 | $B2 | $B3"
check "  body says invalid_credentials" invalid_credentials "$(printf '%s' "$B1" | jget 'j.error')"
login "$E_M" "$PW"
check "success after a failure resets counter" "200|0" "$STATUS|$(counter "$E_M")"

# --- lockout after 5 failures
reset_ip_limit
CODES=""
for _ in 1 2 3 4 5; do login "$E_L" "WrongHorse9"; CODES="$CODES$STATUS "; done
check "five wrong passwords" "401 401 401 401 401 " "$CODES"
login "$E_L" "$PW"
check "6th attempt with the correct password" 423 "$STATUS" "$BODY"
RA="$(printf '%s\n' "$HEADERS" | grep -i '^retry-after:' | awk '{print $2}')"
check "  Retry-After between 1 and 900" yes \
  "$([ -n "$RA" ] && [ "$RA" -ge 1 ] && [ "$RA" -le 900 ] && echo yes || echo no)" "$RA"
check "locked account banned in Auth (direct sign-in)" user_banned \
  "$(curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" "${PK[@]}" \
      -H "Content-Type: application/json" \
      --data-binary "{\"email\":\"$E_L\",\"password\":\"$PW\"}" | jget 'j.error_code')"
check "audit: 5 login_failure + 1 account_locked" "account_locked:1,login_failure:5" \
  "$(sql "select string_agg(event_type || ':' || n, ',' order by event_type) from (
            select event_type, count(*) n from public.audit_log
            where target_id = '$ID_L' group by event_type) x;")"
check "audit metadata has no email or IP" "" \
  "$(sql "select metadata::text from public.audit_log
          where target_id = '$ID_L' and (metadata::text like '%@%' or metadata ? 'ip');")"

# --- lock expires (simulated: move the lock into the past, lift the ban)
sql "update public.profiles set locked_until = now() - interval '1 second' where user_id = '$ID_L';" >/dev/null
curl -s -o /dev/null -X PUT "$API_URL/auth/v1/admin/users/$ID_L" "${SK[@]}" \
  -H "Content-Type: application/json" --data-binary '{"ban_duration":"none"}'
login "$E_L" "$PW"
check "login works after the lock expires" 200 "$STATUS" "$BODY"
check "  counter and lock cleared" "0|" \
  "$(sql "select failed_login_count || '|' || coalesce(locked_until::text, '') from public.profiles where user_id = '$ID_L';")"

# --- 10 wrong-password logins at the same moment
reset_ip_limit
for i in $(seq 1 10); do
  ( curl -s -o /dev/null -w '%{http_code}' -X POST "$FN/auth/login" "${PK[@]}" \
      -H "Content-Type: application/json" \
      --data-binary "{\"email\":\"$E_B\",\"password\":\"WrongHorse9\"}" > "$TMP/burst$i" ) &
done
wait
BURST="$(for f in "$TMP"/burst*; do cat "$f"; echo; done | sort | uniq -c | awk '{print $2"x"$1}' | tr '\n' ' ')"
check "10 simultaneous wrong logins: 5 checked, 5 refused" "401x5 423x5 " "$BURST"
check "  account locked, one account_locked row" "t|1" \
  "$(sql "select (locked_until > now())::text from public.profiles where user_id = '$ID_B';" | cut -c1)|$(sql "select count(*) from public.audit_log where target_id = '$ID_B' and event_type = 'account_locked';")"

# --- per-address limit: fill this address up to 20, the next attempt is 429
reset_ip_limit
login "nobody$SUFFIX" "$PW"
IP_HASH="$(sql "select ip_hash from public.login_attempts limit 1;")"
sql "insert into public.login_attempts (ip_hash) select '$IP_HASH' from generate_series(1, 19);" >/dev/null
login "$E_M" "$PW"
check "21st attempt from one address" 429 "$STATUS" "$BODY"
check "  counter not touched by refused attempt" 0 "$(counter "$E_M")"
reset_ip_limit

# --- input and caller checks
login "not-an-email" "$PW"
check "invalid email" 400 "$STATUS" "$BODY"
login "$E_M" ""
check "empty password" 400 "$STATUS" "$BODY"
login "$E_M" "$PW" -H "Authorization: Bearer $TOKEN"
check "signed-in caller" 403 "$STATUS" "$BODY"
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$FN/auth/login" \
  -H "Content-Type: application/json" --data-binary "{\"email\":\"$E_M\",\"password\":\"$PW\"}")"
check "no publishable key" 401 "$STATUS"
STATUS="$(curl -s -o /dev/null -w '%{http_code}' "$FN/auth/login" "${PK[@]}")"
check "GET on login" 405 "$STATUS"

# --- direct database access with the publishable key
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "$API_URL/rest/v1/rpc/finish_login_attempt" "${PK[@]}" -H "Content-Type: application/json" \
  --data-binary "{\"p_user_id\":\"$ID_L\",\"p_success\":true}")"
check "direct RPC finish_login_attempt refused" 401 "$STATUS"
STATUS="$(curl -s -o /dev/null -w '%{http_code}' "$API_URL/rest/v1/login_attempts?select=*" "${PK[@]}")"
check "direct read of login_attempts refused" 401 "$STATUS"

cleanup
echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
