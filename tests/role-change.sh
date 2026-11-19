#!/usr/bin/env bash
# Local tests for PATCH /membership-api/members/:id/role.
#
# Requires the local stack (npx supabase start) with jwt_expiry = 900.
# Run from the repository root in Git Bash:   bash tests/role-change.sh
#
# Creates its own users with *@example.test addresses and removes them
# before and after. Keys and tokens are never printed.

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
PASS=0
FAIL=0
PK=(-H "apikey: $PUBLISHABLE_KEY")
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
       delete from public.membership_request_attempts;" >/dev/null
}

check() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-58s %s\n' "$1" "$3"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-58s expected %s, got %s  %s\n' \
      "$1" "$2" "$3" "${4:-}"
  fi
}

jget() {
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    let j;try{j=JSON.parse(s)}catch{j=null}
    let v;try{v=eval(process.argv[1])}catch{v=undefined}
    process.stdout.write(v===undefined||v===null?"":String(v))})' "$1"
}

claim() { # token expr  (expr uses p for the decoded payload)
  node -e 'try{const p=JSON.parse(Buffer.from(process.argv[1].split(".")[1],"base64url"));
    const v=eval(process.argv[2]);console.log(v==null?"":v)}catch{console.log("")}' "$1" "$2"
}

# make_user NAME EMAIL ROLE ACTIVE -> prints user id
make_user() {
  local id
  id="$(curl -s -X POST "$API_URL/auth/v1/admin/users" \
    -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SECRET_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "{\"email\":\"$2\",\"password\":\"$PW\",\"email_confirm\":true,\"app_metadata\":{\"role\":\"$3\"}}" \
    | jget 'j.id')"
  sql "insert into public.profiles (user_id, full_name, email, role, active)
       values ('$id', '$1', '$2', '$3', $4);" >/dev/null
  printf '%s' "$id"
}

token_for() {
  curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" "${PK[@]}" \
    -H "Content-Type: application/json" \
    --data-binary "{\"email\":\"$1\",\"password\":\"$PW\"}" | jget 'j.access_token'
}

# set_role TOKEN USER_ID ROLE -> sets STATUS and BODY
set_role() {
  local out
  out="$(curl -s -w '\n%{http_code}' -X PATCH "$FN/members/$2/role" "${PK[@]}" \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    --data-binary "{\"role\":\"$3\"}")"
  STATUS="${out##*$'\n'}"
  BODY="${out%$'\n'*}"
}

list_status() { # token -> HTTP status of the officer-only list
  curl -s -o /dev/null -w '%{http_code}' "$FN/membership-requests" "${PK[@]}" \
    -H "Authorization: Bearer $1"
}

role_changes() {
  sql "select count(*) from public.audit_log a join auth.users u on u.id = a.target_id
       where a.event_type = 'role_changed' and u.email like '%-$RUN_ID@example.test';"
}

cleanup
echo "== role change tests (run $RUN_ID)"

# --- setup
E_O="officer-$RUN_ID@example.test"; E_1="member1-$RUN_ID@example.test"
E_2="member2-$RUN_ID@example.test"; E_P="pending-$RUN_ID@example.test"
ID_O="$(make_user "Officer O" "$E_O" officer true)"
ID_1="$(make_user "Member One" "$E_1" member true)"
ID_2="$(make_user "Member Two" "$E_2" member true)"
curl -s -o /dev/null -X POST "$FN/membership-requests" "${PK[@]}" \
  -H "Content-Type: application/json" \
  --data-binary "{\"fullName\":\"Pending P\",\"email\":\"$E_P\",\"password\":\"$PW\"}"
ID_P="$(sql "select user_id from public.profiles where email = '$E_P';")"
T_O="$(token_for "$E_O")"
check "setup: officer token and pending applicant" yes \
  "$([ -n "$T_O" ] && [ -n "$ID_P" ] && echo yes || echo no)"

check "token lifetime is 900 seconds" 900 "$(claim "$T_O" 'p.exp - p.iat')"

# --- promote member 1
set_role "$T_O" "$ID_1" officer
check "promote member 1" 200 "$STATUS" "$BODY"
check "promote: changed true, previous member" "true|member" \
  "$(printf '%s' "$BODY" | jget 'j.changed + "|" + j.previousRole')"
T_1="$(token_for "$E_1")"
check "member 1 new token role claim" officer "$(claim "$T_1" 'p.app_metadata.role')"
check "member 1 can now use officer routes" 200 "$(list_status "$T_1")"

COUNT_BEFORE="$(role_changes)"
set_role "$T_O" "$ID_1" officer
check "promote again" 200 "$STATUS" "$BODY"
check "promote again: changed false" false "$(printf '%s' "$BODY" | jget 'j.changed')"
check "promote again: no new audit row" "$COUNT_BEFORE" "$(role_changes)"

# --- demote member 1: old officer token stops working in Membership at once
set_role "$T_O" "$ID_1" member
check "demote member 1" 200 "$STATUS" "$BODY"
check "old officer token still says officer" officer "$(claim "$T_1" 'p.app_metadata.role')"
check "old officer token refused by Membership at once" 403 "$(list_status "$T_1")"
check "member 1 new token role claim" member \
  "$(claim "$(token_for "$E_1")" 'p.app_metadata.role')"

# --- last officer
set_role "$T_O" "$ID_O" member
check "only officer demotes themself" 409 "$STATUS" "$BODY"
check "  error is last_officer" last_officer "$(printf '%s' "$BODY" | jget 'j.error')"

# --- handover: promote member 2, then officer O steps down
set_role "$T_O" "$ID_2" officer
check "promote member 2" 200 "$STATUS" "$BODY"
set_role "$T_O" "$ID_O" member
check "officer O demotes themself (another officer exists)" 200 "$STATUS" "$BODY"
check "officer O token now refused" 403 "$(list_status "$T_O")"

# --- two officers demote each other at the same moment
T_2="$(token_for "$E_2")"
set_role "$T_2" "$ID_1" officer
check "member 2 promotes member 1 (two officers)" 200 "$STATUS" "$BODY"
T_1="$(token_for "$E_1")"
( curl -s -o /dev/null -w '%{http_code}' -X PATCH "$FN/members/$ID_2/role" "${PK[@]}" \
    -H "Authorization: Bearer $T_1" -H "Content-Type: application/json" \
    --data-binary '{"role":"member"}' > "$TMP/r1" ) &
( curl -s -o /dev/null -w '%{http_code}' -X PATCH "$FN/members/$ID_1/role" "${PK[@]}" \
    -H "Authorization: Bearer $T_2" -H "Content-Type: application/json" \
    --data-binary '{"role":"member"}' > "$TMP/r2" ) &
wait
RESULTS="$(printf '%s\n%s\n' "$(cat "$TMP/r1")" "$(cat "$TMP/r2")" | sort | tr '\n' ' ')"
case "$RESULTS" in
  "200 403 "|"200 409 ") check "simultaneous demotions: one succeeds" yes yes ;;
  *) check "simultaneous demotions: one succeeds" "200 + 403/409" "$RESULTS" ;;
esac
check "exactly one active officer remains" 1 \
  "$(sql "select count(*) from public.profiles where role = 'officer' and active
          and email like '%-$RUN_ID@example.test';")"
WINNER_EMAIL="$(sql "select email from public.profiles where role = 'officer' and active
                     and email like '%-$RUN_ID@example.test';")"
T_W="$(token_for "$WINNER_EMAIL")"

# --- refused changes
set_role "$T_W" "$ID_P" officer
check "promote pending applicant" 409 "$STATUS" "$BODY"
check "  error is target_not_active" target_not_active "$(printf '%s' "$BODY" | jget 'j.error')"
set_role "$T_O" "$ID_1" officer
check "member token (demoted O)" 403 "$STATUS" "$BODY"
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "$FN/members/$ID_1/role" "${PK[@]}" \
  -H "Content-Type: application/json" --data-binary '{"role":"officer"}')"
check "publishable key only" 401 "$STATUS"
set_role "$T_W" "not-a-uuid" officer
check "invalid user id" 400 "$STATUS" "$BODY"
set_role "$T_W" "$ID_1" admin
check "invalid role" 400 "$STATUS" "$BODY"
set_role "$T_W" "00000000-0000-4000-8000-000000000000" officer
check "unknown user" 404 "$STATUS" "$BODY"
STATUS="$(curl -s -o /dev/null -w '%{http_code}' "$FN/members/$ID_1/role" "${PK[@]}" \
  -H "Authorization: Bearer $T_W")"
check "GET on role path" 405 "$STATUS"

# --- audit log: promote 1, demote 1, promote 2, O steps down,
#     2 promotes 1, one simultaneous demotion = 6 real changes
check "audit log has one role_changed row per real change" 6 "$(role_changes)"
check "audit rows record old and new role" "officer>member" \
  "$(sql "select a.metadata->>'old_role' || '>' || (a.metadata->>'new_role')
          from public.audit_log a where a.target_id = '$ID_O' and a.event_type = 'role_changed';")"

# --- direct database access with the publishable key
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "$API_URL/rest/v1/rpc/change_member_role" "${PK[@]}" -H "Content-Type: application/json" \
  --data-binary "{\"p_target_id\":\"$ID_1\",\"p_actor_id\":\"$ID_O\",\"p_new_role\":\"officer\"}")"
check "direct RPC change_member_role refused" 401 "$STATUS"

cleanup
echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
