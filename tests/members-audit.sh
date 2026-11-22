#!/usr/bin/env bash
# Tests for GET /api/members and GET /api/audit-log on Floci.
#   bash tests/members-audit.sh        (after bash infra/deploy.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh
[ -f infra/out/api.env ] || { echo "Run bash infra/deploy.sh first." >&2; exit 2; }
source infra/out/api.env
source tests/lib.sh
mkdir -p infra/out/tmp

PW="CorrectHorse9"
RUN_ID=$(date +%s)
SUFFIX="-$RUN_ID@example.test"

signin() { curl -s -m 60 -X POST "$API_URL/api/auth/login" -H "Content-Type: application/json" \
  --data-binary "{\"email\":\"$1\",\"password\":\"$PW\"}" | jget 'j.accessToken'; }
user_id() { "$AWS" dynamodb query --table-name ClubUsers --index-name EmailIndex \
  --key-condition-expression 'emailLower = :e' --expression-attribute-values "{\":e\":{\"S\":\"$1\"}}" \
  --query 'Items[0].userId.S' --output text; }
submit() { curl -s -m 60 -X POST "$API_URL/api/membership-requests" -H "Content-Type: application/json" \
  --data-binary "{\"fullName\":\"$1\",\"email\":\"$2\",\"password\":\"$PW\"}" | jget 'j.requestId'; }
patch() { curl -s -m 60 -o /dev/null -X PATCH "$API_URL$1" -H "Authorization: Bearer $2" \
  -H "Content-Type: application/json" --data-binary "$3"; }
get() { # PATH TOKEN [--data-urlencode k=v ...] -> STATUS, BODY
  local p="$1" t="$2"; shift 2
  local tmp="infra/out/tmp/get.$$"
  STATUS=$(curl -s -m 60 -G -o "$tmp" -w '%{http_code}' "$API_URL$p" ${t:+-H "Authorization: Bearer $t"} "$@")
  BODY=$(cat "$tmp"); rm -f "$tmp"
}
names() { printf '%s' "$BODY" | jget "j.members.filter(m=>m.email.endsWith('$SUFFIX')).map(m=>m.fullName).join(', ')"; }

cleanup_test_data
echo "== members and audit-log tests on $API_URL (run $RUN_ID)"

# --- setup: officer Alice approves Bob, Carol and Dan; Dan is then deactivated
ID_O=$(helper make-officer "Alice Smith" "alice$SUFFIX" "$PW")
T_O=$(signin "alice$SUFFIX")
for p in "Bob 100% Real|bob" "Carol_Jones|carol" "Dan Inactive|dan"; do
  patch "/api/membership-requests/$(submit "${p%%|*}" "${p##*|}$SUFFIX")" "$T_O" '{"decision":"approve"}'
done
ID_B=$(user_id "bob$SUFFIX"); ID_D=$(user_id "dan$SUFFIX")
helper set-user "$ID_D" active false
T_B=$(signin "bob$SUFFIX")
check "setup: officer and three members" yes "$([ -n "$T_O" ] && [ -n "$T_B" ] && [ ${#ID_D} -eq 36 ] && echo yes || echo no)"
reset_rate_limits

# --- GET /api/members
get /api/members "$T_O" --data-urlencode "search=$SUFFIX"
check "officer lists active members" 200 "$STATUS" "$BODY"
check "  sorted by name, inactive left out" "Alice Smith, Bob 100% Real, Carol_Jones" "$(names)"
check "  total" 3 "$(printf '%s' "$BODY" | jget 'j.total')"
check "  only documented fields" "active,createdAt,email,fullName,role,userId" "$(printf '%s' "$BODY" | jget 'Object.keys(j.members[0]).sort().join(",")')"
check "  no password hash anywhere" no "$(printf '%s' "$BODY" | grep -q 'passwordHash\|\$2[aby]\$' && echo yes || echo no)"

get /api/members "$T_O" --data-urlencode "search=ALI" --data-urlencode "limit=100";  check "search part of a name, any case" "Alice Smith" "$(names)"
get /api/members "$T_O" --data-urlencode "search=BOB-$RUN_ID@EXAMPLE";             check "search by email, any case" "Bob 100% Real" "$(names)"
get /api/members "$T_O" --data-urlencode "search=%" --data-urlencode "limit=100";  check "search % matches only a literal %" "Bob 100% Real" "$(names)"
get /api/members "$T_O" --data-urlencode "search=_" --data-urlencode "limit=100";  check "search _ matches only a literal _" "Carol_Jones" "$(names)"
get /api/members "$T_O" --data-urlencode "search=x%,role = officer" --data-urlencode "status=all"
check "filter-like search text is plain text" 0 "$(printf '%s' "$BODY" | jget 'j.total')"
get /api/members "$T_O" --data-urlencode "search=$SUFFIX" --data-urlencode "status=inactive"; check "status=inactive" "Dan Inactive" "$(names)"
get /api/members "$T_O" --data-urlencode "search=$SUFFIX" --data-urlencode "status=all";      check "status=all" "Alice Smith, Bob 100% Real, Carol_Jones, Dan Inactive" "$(names)"
get /api/members "$T_O" --data-urlencode "search=$SUFFIX" --data-urlencode "limit=2" --data-urlencode "offset=2"
check "limit 2 offset 2: last page" "Carol_Jones|3" "$(names)|$(printf '%s' "$BODY" | jget 'j.total')"

for bad in "status=banned" "limit=0" "limit=500" "offset=-1" "limit=abc" "search=$(head -c 101 /dev/zero | tr '\0' 'a')"; do
  get /api/members "$T_O" --data-urlencode "$bad"; check "members: invalid ${bad:0:20}" 400 "$STATUS" "$BODY"
done
get /api/members "$T_B"; check "members: member token" 403 "$STATUS" "$BODY"
get /api/members "";     check "members: no token" 401 "$STATUS" "$BODY"
check "members: POST refused by the gateway" 404 "$(curl -s -m 60 -o /dev/null -w '%{http_code}' -X POST "$API_URL/api/members" -H "Authorization: Bearer $T_O")"

# --- real audit entries: promote Bob, demote Bob
patch "/api/members/$ID_B/role" "$T_O" '{"role":"officer"}'
patch "/api/members/$ID_B/role" "$T_O" '{"role":"member"}'

# --- GET /api/audit-log
get /api/audit-log "$T_O" --data-urlencode "limit=100"
check "officer reads the audit log" 200 "$STATUS" "$BODY"
ALL="$BODY"
check "  this run's entries, newest first" "role_changed,role_changed,membership_approved,membership_approved,membership_approved" \
  "$(printf '%s' "$ALL" | jget "j.entries.filter(e=>e.actor&&e.actor.userId==='$ID_O').map(e=>e.eventType).join(',')")"
check "  newest records officer > member" "officer>member" \
  "$(printf '%s' "$ALL" | jget "(e=>e.metadata.oldRole+'>'+e.metadata.newRole)(j.entries.find(e=>e.actor&&e.actor.userId==='$ID_O'))")"
check "  entry fields" "actor,createdAt,eventType,logId,metadata,target" "$(printf '%s' "$ALL" | jget 'Object.keys(j.entries[0]).sort().join(",")')"
check "  actor shows id and name only" "fullName,userId|Alice Smith" \
  "$(printf '%s' "$ALL" | jget "(a=>Object.keys(a).sort().join(',')+'|'+a.fullName)(j.entries.find(e=>e.actor&&e.actor.userId==='$ID_O').actor)")"
check "  no email addresses in the response" no "$(printf '%s' "$ALL" | grep -q '@' && echo yes || echo no)"

# paging: 30 entries with the SAME timestamp, read 7 at a time
helper audit-fill 30 "$ID_D"
get /api/audit-log "$T_O" --data-urlencode "type=login_failure" --data-urlencode "limit=100"
EXPECT=$(printf '%s' "$BODY" | jget "j.entries.filter(e=>e.target?.userId==='$ID_D').map(e=>e.logId).join(',')")
PAGED=""; CURSOR=""
for _ in 1 2 3 4 5; do
  if [ -z "$CURSOR" ]; then get /api/audit-log "$T_O" --data-urlencode "type=login_failure" --data-urlencode "limit=7"
  else get /api/audit-log "$T_O" --data-urlencode "type=login_failure" --data-urlencode "limit=7" --data-urlencode "before=$CURSOR"; fi
  PAGED="$PAGED$(printf '%s' "$BODY" | jget "j.entries.filter(e=>e.target?.userId==='$ID_D').map(e=>e.logId+',').join('')")"
  CURSOR=$(printf '%s' "$BODY" | jget 'j.entries.length ? j.entries[j.entries.length-1].logId : ""')
  [ -z "$CURSOR" ] && break
done
check "paging 7 at a time over 30 equal timestamps" "30|30|yes" \
  "$(echo "$PAGED" | tr ',' '\n' | grep -c .)|$(echo "$PAGED" | tr ',' '\n' | grep . | sort -u | wc -l | tr -d ' ')|$([ "${PAGED%,}" = "$EXPECT" ] && echo yes || echo no)"

get /api/audit-log "$T_O" --data-urlencode "type=membership_approved" --data-urlencode "limit=100"
check "type filter returns only that type" membership_approved "$(printf '%s' "$BODY" | jget '[...new Set(j.entries.map(e=>e.eventType))].join(",")')"

for bad in "type=hacked" "limit=0" "limit=101" "before=not-a-uuid" "before=00000000-0000-4000-8000-000000000000"; do
  get /api/audit-log "$T_O" --data-urlencode "$bad"; check "audit-log: invalid ${bad:0:22}" 400 "$STATUS" "$BODY"
done
get /api/audit-log "$T_B"; check "audit-log: member token" 403 "$STATUS" "$BODY"
get /api/audit-log "";     check "audit-log: no token" 401 "$STATUS" "$BODY"
check "audit-log: DELETE refused by the gateway" 404 "$(curl -s -m 60 -o /dev/null -w '%{http_code}' -X DELETE "$API_URL/api/audit-log" -H "Authorization: Bearer $T_O")"

cleanup_test_data
finish
