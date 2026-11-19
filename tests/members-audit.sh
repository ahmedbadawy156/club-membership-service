#!/usr/bin/env bash
# Local tests for GET /membership-api/members and GET /membership-api/audit-log,
# and for the append-only audit log.
#
# Requires the local stack (npx supabase start). Run from the repository
# root in Git Bash:   bash tests/members-audit.sh
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
SUFFIX="-$RUN_ID@example.test"
PASS=0
FAIL=0
PK=(-H "apikey: $PUBLISHABLE_KEY")
SK=(-H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SECRET_KEY")

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

make_user() { # NAME EMAIL ROLE ACTIVE -> user id
  local id
  id="$(curl -s -X POST "$API_URL/auth/v1/admin/users" "${SK[@]}" \
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

# get PATH TOKEN [--data-urlencode k=v ...] -> sets STATUS and BODY
get() {
  local path="$1" token="$2"; shift 2
  local auth=()
  [ -n "$token" ] && auth=(-H "Authorization: Bearer $token")
  local out
  out="$(curl -s -G -w '\n%{http_code}' "$FN$path" "${PK[@]}" "${auth[@]}" "$@")"
  STATUS="${out##*$'\n'}"
  BODY="${out%$'\n'*}"
}

# names of this run's members in the response, in order
run_names() {
  printf '%s' "$BODY" | jget "j.members.filter(m=>m.email.endsWith('$SUFFIX')).map(m=>m.fullName).join(', ')"
}

cleanup
echo "== members and audit-log tests (run $RUN_ID)"

# --- setup
ID_O="$(make_user "Alice Smith" "alice$SUFFIX" officer true)"
ID_B="$(make_user "Bob 100% Real" "bob$SUFFIX" member true)"
ID_C="$(make_user "Carol_Jones" "carol$SUFFIX" member true)"
curl -s -o /dev/null -X POST "$FN/membership-requests" "${PK[@]}" \
  -H "Content-Type: application/json" \
  --data-binary "{\"fullName\":\"Dan Pending\",\"email\":\"dan$SUFFIX\",\"password\":\"$PW\"}"
T_O="$(token_for "alice$SUFFIX")"
T_B="$(token_for "bob$SUFFIX")"
check "setup: officer and member tokens" yes \
  "$([ -n "$T_O" ] && [ -n "$T_B" ] && echo yes || echo no)"

# --- GET /members
get /members "$T_O" --data-urlencode "search=$SUFFIX"
check "officer lists active members" 200 "$STATUS" "$BODY"
check "  active members sorted by name" "Alice Smith, Bob 100% Real, Carol_Jones" "$(run_names)"
check "  total matches" 3 "$(printf '%s' "$BODY" | jget 'j.total')"
check "  only the documented fields" "active,createdAt,email,fullName,role,userId" \
  "$(printf '%s' "$BODY" | jget 'Object.keys(j.members[0]).sort().join(",")')"

get /members "$T_O" --data-urlencode "search=ALI" --data-urlencode "limit=100"
check "search part of a name, any case" "Alice Smith" "$(run_names)"
get /members "$T_O" --data-urlencode "search=BOB-$RUN_ID@EXAMPLE"
check "search by email, any case" "Bob 100% Real" "$(run_names)"
get /members "$T_O" --data-urlencode "search=%" --data-urlencode "limit=100"
check "search % matches only a literal %" "Bob 100% Real" "$(run_names)"
get /members "$T_O" --data-urlencode "search=_" --data-urlencode "limit=100"
check "search _ matches only a literal _" "Carol_Jones" "$(run_names)"
get /members "$T_O" --data-urlencode "search=x%,role.eq.officer" --data-urlencode "status=all"
check "filter-like search text is plain text" "0" "$(printf '%s' "$BODY" | jget 'j.total')"

get /members "$T_O" --data-urlencode "search=$SUFFIX" --data-urlencode "status=inactive"
check "status=inactive shows the applicant" "Dan Pending" "$(run_names)"
get /members "$T_O" --data-urlencode "search=$SUFFIX" --data-urlencode "status=all"
check "status=all shows everyone" "Alice Smith, Bob 100% Real, Carol_Jones, Dan Pending" "$(run_names)"
get /members "$T_O" --data-urlencode "search=$SUFFIX" --data-urlencode "limit=2" --data-urlencode "offset=2"
check "limit 2 offset 2: last page" "Carol_Jones|3" \
  "$(run_names)|$(printf '%s' "$BODY" | jget 'j.total')"

for bad in "status=banned" "limit=0" "limit=500" "offset=-1" "limit=abc" \
           "search=$(head -c 101 /dev/zero | tr '\0' 'a')"; do
  get /members "$T_O" --data-urlencode "$bad"
  check "members: invalid ${bad:0:20}" 400 "$STATUS" "$BODY"
done

get /members "$T_B"
check "members: member token" 403 "$STATUS" "$BODY"
get /members ""
check "members: publishable key only" 401 "$STATUS" "$BODY"
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$FN/members" "${PK[@]}" \
  -H "Authorization: Bearer $T_O")"
check "members: POST not allowed" 405 "$STATUS"

# --- create real audit entries: approve Dan, promote and demote Bob
REQ_D="$(sql "select request_id from public.membership_requests where email = 'dan$SUFFIX';")"
for args in "membership-requests/$REQ_D|{\"decision\":\"approve\"}" \
            "members/$ID_B/role|{\"role\":\"officer\"}" \
            "members/$ID_B/role|{\"role\":\"member\"}"; do
  curl -s -o /dev/null -X PATCH "$FN/${args%%|*}" "${PK[@]}" \
    -H "Authorization: Bearer $T_O" -H "Content-Type: application/json" \
    --data-binary "${args#*|}"
done

# --- GET /audit-log
get /audit-log "$T_O" --data-urlencode "limit=100"
check "officer reads the audit log" 200 "$STATUS" "$BODY"
ALL="$BODY"
check "  this run's entries, newest first" \
  "role_changed,role_changed,membership_approved" \
  "$(printf '%s' "$ALL" | jget "j.entries.filter(e=>e.actor&&e.actor.userId==='$ID_O').map(e=>e.eventType).join(',')")"
check "  newest entry records officer > member" "officer>member" \
  "$(printf '%s' "$ALL" | jget "(e=>e.metadata.old_role+'>'+e.metadata.new_role)(j.entries.find(e=>e.actor&&e.actor.userId==='$ID_O'))")"
check "  entry fields" "actor,createdAt,eventType,logId,metadata,target" \
  "$(printf '%s' "$ALL" | jget 'Object.keys(j.entries[0]).sort().join(",")')"
check "  actor shows id and name only" "fullName,userId|Alice Smith" \
  "$(printf '%s' "$ALL" | jget "(a=>Object.keys(a).sort().join(',')+'|'+a.fullName)(j.entries.find(e=>e.actor&&e.actor.userId==='$ID_O').actor)")"
check "  no email addresses in the response" no \
  "$(printf '%s' "$ALL" | grep -q '@' && echo yes || echo no)"

# paging with limit 1 must give the same first three entries as one page
EXPECT="$(printf '%s' "$ALL" | jget 'j.entries.slice(0,3).map(e=>e.logId).join(",")')"
PAGED=""; CURSOR=""
for _ in 1 2 3; do
  if [ -z "$CURSOR" ]; then get /audit-log "$T_O" --data-urlencode "limit=1"
  else get /audit-log "$T_O" --data-urlencode "limit=1" --data-urlencode "before=$CURSOR"; fi
  CURSOR="$(printf '%s' "$BODY" | jget 'j.entries[0].logId')"
  PAGED="${PAGED:+$PAGED,}$CURSOR"
done
check "paging with before= matches the single page" "$EXPECT" "$PAGED"

get /audit-log "$T_O" --data-urlencode "type=membership_approved" --data-urlencode "limit=100"
check "type filter returns only that type" membership_approved \
  "$(printf '%s' "$BODY" | jget '[...new Set(j.entries.map(e=>e.eventType))].join(",")')"

for bad in "type=hacked" "limit=0" "limit=101" "before=not-a-uuid" \
           "before=00000000-0000-4000-8000-000000000000"; do
  get /audit-log "$T_O" --data-urlencode "$bad"
  check "audit-log: invalid ${bad:0:20}" 400 "$STATUS" "$BODY"
done
get /audit-log "$T_B"
check "audit-log: member token" 403 "$STATUS" "$BODY"
get /audit-log ""
check "audit-log: publishable key only" 401 "$STATUS" "$BODY"

# --- append-only audit log, even with the secret key
LOG_ID="$(printf '%s' "$ALL" | jget "j.entries.find(e=>e.actor&&e.actor.userId==='$ID_O').logId")"
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X PATCH \
  "$API_URL/rest/v1/audit_log?log_id=eq.$LOG_ID" "${SK[@]}" \
  -H "Content-Type: application/json" --data-binary '{"metadata":{}}')"
case "$STATUS" in 401|403) R=refused ;; *) R="HTTP $STATUS" ;; esac
check "secret key UPDATE on audit_log" refused "$R"
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
  "$API_URL/rest/v1/audit_log?log_id=eq.$LOG_ID" "${SK[@]}")"
case "$STATUS" in 401|403) R=refused ;; *) R="HTTP $STATUS" ;; esac
check "secret key DELETE on audit_log" refused "$R"
check "audit entry unchanged" "officer>member" \
  "$(sql "select (metadata->>'old_role') || '>' || (metadata->>'new_role')
          from public.audit_log where log_id = '$LOG_ID';")"

# --- direct database access with the publishable key
for fn in search_members list_audit_log; do
  STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "$API_URL/rest/v1/rpc/$fn" "${PK[@]}" -H "Content-Type: application/json" \
    --data-binary '{"p_limit":5}')"
  check "direct RPC $fn refused" 401 "$STATUS"
done

cleanup
echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
