#!/usr/bin/env bash
# Tests for PATCH /api/members/{id}/role on Floci: last-officer rule,
# simultaneous demotions, role taking effect at once in Membership.
#   bash tests/role-change.sh        (after bash infra/deploy.sh)
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
claim() { node -e 'try{const p=JSON.parse(Buffer.from(process.argv[1].split(".")[1],"base64url"));console.log(p[process.argv[2]])}catch{console.log("")}' "$1" "$2"; }
user_id() { "$AWS" dynamodb query --table-name ClubUsers --index-name EmailIndex \
  --key-condition-expression 'emailLower = :e' --expression-attribute-values "{\":e\":{\"S\":\"$1\"}}" \
  --query 'Items[0].userId.S' --output text; }
set_role() { # TOKEN USERID ROLE -> STATUS, BODY_OUT
  local tmp="infra/out/tmp/role.$$"
  STATUS=$(curl -s -m 60 -o "$tmp" -w '%{http_code}' -X PATCH "$API_URL/api/members/$2/role" \
    ${1:+-H "Authorization: Bearer $1"} -H "Content-Type: application/json" --data-binary "{\"role\":\"$3\"}")
  BODY_OUT=$(cat "$tmp"); rm -f "$tmp"
}
list_status() { curl -s -m 60 -o /dev/null -w '%{http_code}' "$API_URL/api/membership-requests" -H "Authorization: Bearer $1"; }
submit() { curl -s -m 60 -X POST "$API_URL/api/membership-requests" -H "Content-Type: application/json" \
  --data-binary "{\"fullName\":\"$1\",\"email\":\"$2\",\"password\":\"$PW\"}" | jget 'j.requestId'; }
approve() { curl -s -m 60 -o /dev/null -X PATCH "$API_URL/api/membership-requests/$1" \
  -H "Authorization: Bearer $2" -H "Content-Type: application/json" --data-binary '{"decision":"approve"}'; }
role_changes() { "$AWS" dynamodb scan --table-name AuditLog --output json | \
  jget "j.Items.filter(e=>e.eventType.S==='role_changed' && [$1].includes(e.targetId?.S)).length"; }
officer_counter() { "$AWS" dynamodb get-item --table-name ClubUsers --key '{"userId":{"S":"META#officers"}}' --query 'Item.count.N' --output text; }
# Only test officers count: this Floci may also hold real officer accounts,
# which the test never touches. isolate_officers sets the officer counter to
# the test officers alone, so the club behaves as if they were its only
# officers; cleanup (also on exit) restores the real count.
active_officers() { "$AWS" dynamodb scan --table-name ClubUsers --output json | \
  jget 'j.Items.filter(u=>u.role?.S==="officer"&&u.active?.BOOL===true&&(u.emailLower?.S||"").includes("@example.test")).length'; }
isolate_officers() { helper isolate-officers >/dev/null; }
trap cleanup_test_data EXIT

cleanup_test_data
echo "== role change tests on $API_URL (run $RUN_ID)"

# --- setup
E_O="officer$SUFFIX"; E_1="member1$SUFFIX"; E_2="member2$SUFFIX"; E_3="member3$SUFFIX"
ID_O=$(helper make-officer "Officer O" "$E_O" "$PW")
T_O=$(signin "$E_O")
for e in "$E_1" "$E_2" "$E_3"; do approve "$(submit "Member ${e%%-*}" "$e")" "$T_O"; done
ID_1=$(user_id "$E_1"); ID_2=$(user_id "$E_2"); ID_3=$(user_id "$E_3")
check "setup: officer and three members" yes "$([ -n "$T_O" ] && [ ${#ID_3} -eq 36 ] && echo yes || echo no)"
isolate_officers
check "setup: officer counter covers only the test officer" 1 "$(officer_counter)"
reset_rate_limits

# --- promote member 1
set_role "$T_O" "$ID_1" officer
check "promote member 1" 200 "$STATUS" "$BODY_OUT"
check "  changed true, previous role member" "true|member|officer" "$(printf '%s' "$BODY_OUT" | jget 'j.changed+"|"+j.previousRole+"|"+j.role')"
T_1=$(signin "$E_1")
check "  member 1's next login token says officer" officer "$(claim "$T_1" role)"
check "  member 1 can now use officer routes" 200 "$(list_status "$T_1")"
check "  officer counter matches the officers" "$(active_officers)" "$(officer_counter)"

BEFORE=$(role_changes "'$ID_1'")
set_role "$T_O" "$ID_1" officer
check "promote again: changed false" "200|false" "$STATUS|$(printf '%s' "$BODY_OUT" | jget 'j.changed')"
check "  no new audit entry" "$BEFORE" "$(role_changes "'$ID_1'")"

# --- demote member 1: the old officer token stops working in Membership at once
set_role "$T_O" "$ID_1" member
check "demote member 1" 200 "$STATUS" "$BODY_OUT"
check "  old token still says officer" officer "$(claim "$T_1" role)"
check "  but Membership refuses it at once" 403 "$(list_status "$T_1")"
check "  next login token says member" member "$(claim "$(signin "$E_1")" role)"

# --- last officer
set_role "$T_O" "$ID_O" member
check "only officer demotes themself" "409|last_officer" "$STATUS|$(printf '%s' "$BODY_OUT" | jget 'j.error')"
check "  still an officer" 200 "$(list_status "$T_O")"

# --- handover: promote member 2, then officer O steps down
set_role "$T_O" "$ID_2" officer; check "promote member 2" 200 "$STATUS" "$BODY_OUT"
set_role "$T_O" "$ID_O" member;  check "O demotes themself (another officer exists)" 200 "$STATUS" "$BODY_OUT"
check "  O's token now refused" 403 "$(list_status "$T_O")"
check "  counter matches the officers" "$(active_officers)" "$(officer_counter)"
reset_rate_limits

# --- two officers demote each other at the same moment
T_2=$(signin "$E_2")
set_role "$T_2" "$ID_1" officer; check "member 2 promotes member 1 (two officers)" 200 "$STATUS" "$BODY_OUT"
T_1=$(signin "$E_1")
TMPD=infra/out/tmp/race.$$; mkdir -p "$TMPD"
( curl -s -m 60 -o /dev/null -w '%{http_code}' -X PATCH "$API_URL/api/members/$ID_2/role" -H "Authorization: Bearer $T_1" \
    -H "Content-Type: application/json" --data-binary '{"role":"member"}' > "$TMPD/1" ) &
( curl -s -m 60 -o /dev/null -w '%{http_code}' -X PATCH "$API_URL/api/members/$ID_1/role" -H "Authorization: Bearer $T_2" \
    -H "Content-Type: application/json" --data-binary '{"role":"member"}' > "$TMPD/2" ) &
wait
R=$(printf '%s\n%s\n' "$(cat "$TMPD/1")" "$(cat "$TMPD/2")" | sort | paste -sd' ')
case "$R" in "200 403"|"200 409") check "simultaneous demotions: exactly one succeeds" yes yes ;;
  *) check "simultaneous demotions: exactly one succeeds" "200 + 403/409" "$R" ;; esac
rm -rf "$TMPD"
check "  exactly one officer left among them" 1 \
  "$("$AWS" dynamodb scan --table-name ClubUsers --output json | jget "j.Items.filter(u=>['$ID_1','$ID_2'].includes(u.userId.S)&&u.role.S==='officer').length")"
check "  counter matches the officers" "$(active_officers)" "$(officer_counter)"
WINNER_EMAIL=$("$AWS" dynamodb scan --table-name ClubUsers --output json | jget "(j.Items.find(u=>['$ID_1','$ID_2'].includes(u.userId.S)&&u.role.S==='officer')||{}).email?.S")
T_W=$(signin "$WINNER_EMAIL")

# --- refused changes
helper set-user "$ID_3" active false; isolate_officers
set_role "$T_W" "$ID_3" officer
check "promote a deactivated member" "409|target_not_active" "$STATUS|$(printf '%s' "$BODY_OUT" | jget 'j.error')"
helper set-user "$ID_3" active true; isolate_officers
set_role "$(signin "$E_3")" "$ID_1" officer; check "member token" 403 "$STATUS" "$BODY_OUT"
set_role "" "$ID_1" officer;                 check "no token" 401 "$STATUS" "$BODY_OUT"
set_role "$T_W" "not-a-uuid" officer;        check "invalid user id" 400 "$STATUS" "$BODY_OUT"
set_role "$T_W" "$ID_3" admin;               check "invalid role" 400 "$STATUS" "$BODY_OUT"
set_role "$T_W" "00000000-0000-4000-8000-000000000000" officer; check "unknown user" 404 "$STATUS" "$BODY_OUT"
check "GET on the role path: refused by the gateway" 404 \
  "$(curl -s -m 60 -o /dev/null -w '%{http_code}' "$API_URL/api/members/$ID_3/role" -H "Authorization: Bearer $T_W")"

# --- audit: promote 1, demote 1, promote 2, O steps down, 2 promotes 1,
#     one simultaneous demotion = 6 real changes
check "audit has one role_changed per real change" 6 "$(role_changes "'$ID_O','$ID_1','$ID_2','$ID_3'")"
check "  entries record old and new role" "officer>member" \
  "$("$AWS" dynamodb scan --table-name AuditLog --output json | jget "(e=>e.metadata.M.oldRole.S+'>'+e.metadata.M.newRole.S)(j.Items.find(e=>e.eventType.S==='role_changed'&&e.targetId?.S==='$ID_O'))")"

cleanup_test_data
finish
