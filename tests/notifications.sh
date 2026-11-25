#!/usr/bin/env bash
# Member notices: SNS topic -> notifier Lambda -> MemberNotifications, read
# with GET /api/notifications.
#   bash tests/notifications.sh        (after bash infra/deploy.sh)
# Sources of notices: this service (approval, role change) and the club bus
# (EventCancelled, SeatPromoted from Events). The last part goes through the
# real Events API when ../club-events-service is deployed.
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
decide() { curl -s -m 60 -o /dev/null -w '%{http_code}' -X PATCH "$API_URL/api/membership-requests/$1" \
  -H "Authorization: Bearer $2" -H "Content-Type: application/json" --data-binary "{\"decision\":\"$3\"}"; }
set_role() { curl -s -m 60 -o /dev/null -w '%{http_code}' -X PATCH "$API_URL/api/members/$2/role" \
  -H "Authorization: Bearer $1" -H "Content-Type: application/json" --data-binary "{\"role\":\"$3\"}"; }
get() { # PATH TOKEN -> STATUS, BODY
  local tmp="infra/out/tmp/get.$$"
  STATUS=$(curl -s -m 60 -o "$tmp" -w '%{http_code}' "$API_URL$1" ${2:+-H "Authorization: Bearer $2"})
  BODY=$(cat "$tmp"); rm -f "$tmp"
}
# Notice titles of a user, newest first, read straight from the table.
titles_of() { "$AWS" dynamodb query --table-name MemberNotifications --key-condition-expression 'userId = :u' \
  --expression-attribute-values "{\":u\":{\"S\":\"$1\"}}" --output json | \
  jget 'j.Items.sort((a,b)=>a.sortKey.S<b.sortKey.S?1:-1).map(i=>i.title.S).join(";")'; }
count_of() { "$AWS" dynamodb query --table-name MemberNotifications --key-condition-expression 'userId = :u' \
  --expression-attribute-values "{\":u\":{\"S\":\"$1\"}}" --select COUNT --query Count --output text; }
# wait_count USERID N: poll until the user has N notices (max 15 s); prints the count
wait_count() {
  local i n
  for i in $(seq 1 15); do n=$(count_of "$1"); [ "$n" -ge "$2" ] && break; sleep 1; done
  printf '%s' "$n"
}
uuid() { node -e 'process.stdout.write(require("crypto").randomUUID())'; }
# bus KIND JSON_DETAIL: put a message on the club bus as Events would
bus() {
  node -e 'require("fs").writeFileSync("infra/out/tmp/bus-entry.json", JSON.stringify([{
    EventBusName: "campus-club-bus", Source: process.argv[3] || "club.events", DetailType: process.argv[1], Detail: process.argv[2] }]))' \
    -- "$1" "$2" "${3:-}"
  "$AWS" events put-events --entries file://infra/out/tmp/bus-entry.json --query FailedEntryCount --output text
}
# sns JSON: publish straight to the topic (admin keys)
# The Announcements worker also posts about bus events; remove those posts.
drop_event_posts() {
  local a
  for a in $("$AWS" dynamodb scan --table-name Announcements --output json 2>/dev/null | jget "j.Items.filter(a=>a.eventId?.S==='$1').map(a=>a.announcementId.S).join(' ')"); do
    "$AWS" dynamodb delete-item --table-name Announcements --key "{\"announcementId\":{\"S\":\"$a\"}}" >/dev/null 2>&1
  done
}
sns() { "$AWS" sns publish --topic-arn "$TOPIC_ARN" --message "$1" --query MessageId --output text; }

cleanup_test_data
trap cleanup_test_data EXIT
echo "== notification tests on $API_URL (run $RUN_ID)"

# --- the wiring ----------------------------------------------------------------------
check "topic exists" "$TOPIC_ARN" "$("$AWS" sns get-topic-attributes --topic-arn "$TOPIC_ARN" --query Attributes.TopicArn --output text 2>&1)"
check "topic pushes to the notifier Lambda" "lambda|arn:aws:lambda:$REGION:$ACCOUNT:function:$NOTIFIER" \
  "$("$AWS" sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --output json | jget "(s=>s.Protocol+'|'+s.Endpoint)(j.Subscriptions.find(s=>s.Protocol==='lambda'))")"
check "topic policy: only this account and the club bus rule may publish" \
  "OwnAccount,OnlyTheClubBusRule|arn:aws:events:$REGION:$ACCOUNT:rule/$BUS/$RULE" \
  "$("$AWS" sns get-topic-attributes --topic-arn "$TOPIC_ARN" --query Attributes.Policy --output text | \
     jget 'j.Statement.map(s=>s.Sid).join()+"|"+j.Statement[1].Condition.ArnEquals["aws:SourceArn"]')"
check "rule forwards EventCancelled and SeatPromoted from club.events" \
  '{"source":["club.events"],"detail-type":["EventCancelled","SeatPromoted"]}' \
  "$("$AWS" events describe-rule --name "$RULE" --event-bus-name "$BUS" --query EventPattern --output text | jget 'JSON.stringify(j)')"
check "rule target is the topic" "$TOPIC_ARN" \
  "$("$AWS" events list-targets-by-rule --rule "$RULE" --event-bus-name "$BUS" --query 'Targets[0].Arn' --output text)"
check "notifier runs under its own role" "arn:aws:iam::$ACCOUNT:role/$NOTIFIER_ROLE" \
  "$("$AWS" lambda get-function-configuration --function-name "$NOTIFIER" --query Role --output text)"
check "old notices expire (TTL on expiresAt)" "ENABLED|expiresAt" \
  "$("$AWS" dynamodb describe-time-to-live --table-name MemberNotifications --output json | jget 'j.TimeToLiveDescription.TimeToLiveStatus+"|"+j.TimeToLiveDescription.AttributeName')"

# --- setup: an officer; Ann and Ben join ---------------------------------------------
ID_O=$(helper make-officer "Olive Officer" "olive$SUFFIX" "$PW")
T_O=$(signin "olive$SUFFIX")
R_ANN=$(submit "Ann Member" "ann$SUFFIX"); R_BEN=$(submit "Ben Member" "ben$SUFFIX"); R_CAT=$(submit "Cat Rejected" "cat$SUFFIX")
check "officer approves Ann" 200 "$(decide "$R_ANN" "$T_O" approve)"
check "officer approves Ben" 200 "$(decide "$R_BEN" "$T_O" approve)"
check "officer rejects Cat" 200 "$(decide "$R_CAT" "$T_O" reject)"
ID_ANN=$(user_id "ann$SUFFIX"); ID_BEN=$(user_id "ben$SUFFIX")
reset_rate_limits

# --- approval -> welcome notice ---------------------------------------------------------
check "Ann gets one notice after approval" 1 "$(wait_count "$ID_ANN" 1)"
T_ANN=$(signin "ann$SUFFIX"); T_BEN=$(signin "ben$SUFFIX")
get /api/notifications "$T_ANN"
check "GET /api/notifications" 200 "$STATUS"
check "  welcome notice, unread" "Welcome to the club|true|MembershipApproved" \
  "$(printf '%s' "$BODY" | jget 'j.notifications[0].title+"|"+j.notifications[0].unread+"|"+j.notifications[0].type')"
check "  unreadCount 1" 1 "$(printf '%s' "$BODY" | jget j.unreadCount)"
check "  fields shown to the member" "createdAt,id,link,text,title,type,unread" \
  "$(printf '%s' "$BODY" | jget 'Object.keys(j.notifications[0]).sort().join()')"
check "approving Ann again (already decided: 200, no change)" 200 "$(decide "$R_ANN" "$T_O" approve)"
sleep 3
check "  and sends no second welcome" 1 "$(count_of "$ID_ANN")"

# --- role change -> notice (only for a real change) ----------------------------------------
check "officer promotes Ben" 200 "$(set_role "$T_O" "$ID_BEN" officer)"
check "Ben: 'You are now an officer'" "You are now an officer;Welcome to the club" \
  "$(wait_count "$ID_BEN" 2 >/dev/null; titles_of "$ID_BEN")"
check "promoting Ben again (no change)" 200 "$(set_role "$T_O" "$ID_BEN" officer)"
sleep 3
check "  sends no notice" 2 "$(count_of "$ID_BEN")"
check "officer demotes Ben" 200 "$(set_role "$T_O" "$ID_BEN" member)"
check "Ben: 'Your role is now member'" "Your role is now member" "$(wait_count "$ID_BEN" 3 >/dev/null; titles_of "$ID_BEN" | cut -d';' -f1)"

# --- notices from the club bus (as the Events service sends them) ----------------------------
E1=$(uuid); START=$(node -e 'process.stdout.write(new Date(Date.now()+2*864e5).toISOString())')
check "SeatPromoted for Ann on the bus" 0 \
  "$(bus SeatPromoted "{\"eventId\":\"$E1\",\"title\":\"Robotics night\",\"startsAt\":\"$START\",\"location\":\"Hall A\",\"userId\":\"$ID_ANN\"}")"
check "Ann: 'You got a seat'" "You got a seat: Robotics night" "$(wait_count "$ID_ANN" 2 >/dev/null; titles_of "$ID_ANN" | cut -d';' -f1)"
get /api/notifications "$T_ANN"
check "  links to the event page" "events/event.html?id=$E1" "$(printf '%s' "$BODY" | jget 'j.notifications[0].link')"
check "EventCancelled for Ann and Ben on the bus" 0 \
  "$(bus EventCancelled "{\"eventId\":\"$E1\",\"title\":\"Robotics night\",\"startsAt\":\"$START\",\"location\":\"Hall A\",\"by\":\"$ID_O\",\"memberIds\":[\"$ID_ANN\",\"$ID_BEN\"]}")"
check "Ann: 'Cancelled: Robotics night'" "Cancelled: Robotics night" "$(wait_count "$ID_ANN" 3 >/dev/null; titles_of "$ID_ANN" | cut -d';' -f1)"
check "Ben: 'Cancelled: Robotics night'" "Cancelled: Robotics night" "$(wait_count "$ID_BEN" 4 >/dev/null; titles_of "$ID_BEN" | cut -d';' -f1)"
check "the officer (no RSVP) got nothing" 0 "$(count_of "$ID_O")"
check "EventPublished is not forwarded to members" 0 \
  "$(bus EventPublished "{\"eventId\":\"$E1\",\"title\":\"Not for members\",\"startsAt\":\"$START\",\"location\":\"x\",\"by\":\"$ID_O\"}")"
check "SeatPromoted from another source is not forwarded" 0 \
  "$(bus SeatPromoted "{\"eventId\":\"$E1\",\"title\":\"Fake seat\",\"startsAt\":\"$START\",\"location\":\"x\",\"userId\":\"$ID_ANN\"}" club.fake)"
sleep 4
check "  Ann still has 3 notices" 3 "$(count_of "$ID_ANN")"

# --- SNS may deliver twice: same message id -> one notice ---------------------------------------
DUP="{\"id\":\"dup-$RUN_ID\",\"source\":\"club.membership\",\"detail-type\":\"RoleChanged\",\"time\":\"$(node -e 'process.stdout.write(new Date().toISOString())')\",\"detail\":{\"userId\":\"$ID_ANN\",\"role\":\"officer\"}}"
sns "$DUP" >/dev/null; sns "$DUP" >/dev/null
wait_count "$ID_ANN" 4 >/dev/null; sleep 3
check "the same message twice: one notice" 4 "$(count_of "$ID_ANN")"

# --- messages the notifier drops -------------------------------------------------------------------
sns "{\"id\":\"bad1-$RUN_ID\",\"source\":\"club.evil\",\"detail-type\":\"RoleChanged\",\"detail\":{\"userId\":\"$ID_ANN\",\"role\":\"officer\"}}" >/dev/null
sns "{\"id\":\"bad2-$RUN_ID\",\"source\":\"club.membership\",\"detail-type\":\"RoleChanged\",\"detail\":{\"userId\":\"$ID_ANN\",\"role\":\"admin\"}}" >/dev/null
sns "not json at all" >/dev/null
sleep 5
check "unknown source, bad role, not JSON: no notices" 4 "$(count_of "$ID_ANN")"
LOGS=$("$AWS" logs tail "$NOTIFIER_LOG_GROUP" --since 10m --format short 2>/dev/null)
check "  each one logged as dropped" yes "$([ "$(printf '%s' "$LOGS" | grep -c notice_dropped)" -ge 3 ] && echo yes || echo no)"
check "  logs never contain message bodies or names" 0 "$(printf '%s' "$LOGS" | grep -c 'not json at all\|club.evil\|Robotics night\|Ann Member' || true)"

# --- own notices only, unread and seen ---------------------------------------------------------------
get /api/notifications "$T_BEN"
check "Ben sees only his own notices" "$(count_of "$ID_BEN")|0" \
  "$(printf '%s' "$BODY" | jget "j.notifications.length+'|'+j.notifications.filter(n=>/seat/i.test(n.title)).length")"
get "/api/notifications?userId=$ID_ANN" "$T_BEN"
check "  asking for Ann's id in the query still returns Ben's" "$(count_of "$ID_BEN")" "$(printf '%s' "$BODY" | jget 'j.notifications.length')"
get /api/notifications "$T_ANN"
check "Ann: 4 unread" 4 "$(printf '%s' "$BODY" | jget j.unreadCount)"
check "  newest first" yes "$(printf '%s' "$BODY" | jget 'j.notifications.every((n,i,a)=>!i||a[i-1].createdAt>=n.createdAt)?"yes":"no"')"
check "POST /api/notifications/seen" 204 "$(curl -s -m 60 -o /dev/null -w '%{http_code}' -X POST "$API_URL/api/notifications/seen" -H "Authorization: Bearer $T_ANN")"
get /api/notifications "$T_ANN"
check "  unreadCount 0, all read" "0|0" "$(printf '%s' "$BODY" | jget "j.unreadCount+'|'+j.notifications.filter(n=>n.unread).length")"
sleep 1
bus SeatPromoted "{\"eventId\":\"$(uuid)\",\"title\":\"Chess club\",\"startsAt\":\"$START\",\"location\":\"Room 2\",\"userId\":\"$ID_ANN\"}" >/dev/null
wait_count "$ID_ANN" 5 >/dev/null
get /api/notifications "$T_ANN"
check "  a newer notice is unread again" "1|You got a seat: Chess club|true" \
  "$(printf '%s' "$BODY" | jget "j.unreadCount+'|'+j.notifications[0].title+'|'+j.notifications[0].unread")"
get "/api/notifications?limit=2" "$T_ANN"
check "limit=2 returns 2" 2 "$(printf '%s' "$BODY" | jget 'j.notifications.length')"
get "/api/notifications?limit=0" "$T_ANN";  check "limit=0 refused" 400 "$STATUS"
get "/api/notifications?limit=abc" "$T_ANN"; check "limit=abc refused" 400 "$STATUS"
get /api/notifications "";  check "no token: 401" 401 "$STATUS"
check "POST seen without a token: 401" 401 "$(curl -s -m 60 -o /dev/null -w '%{http_code}' -X POST "$API_URL/api/notifications/seen")"
check "DELETE is not a route (gateway)" 404 "$(curl -s -m 60 -o /dev/null -w '%{http_code}' -X DELETE "$API_URL/api/notifications" -H "Authorization: Bearer $T_ANN")"
check "no notice ever carries an email" 0 \
  "$("$AWS" dynamodb scan --table-name MemberNotifications --output json | jget "j.Items.filter(i=>/@/.test(JSON.stringify(i))).length")"

# --- end to end through the real Events API --------------------------------------------------------
EVENTS_ENV=../club-events-service/infra/out/api.env
if [ -f "$EVENTS_ENV" ]; then
  EVENTS_URL=$(grep '^API_URL=' "$EVENTS_ENV" | cut -d= -f2 | tr -d '\r')
  ev() { curl -s -m 60 -o infra/out/tmp/ev.json -w '%{http_code}' -X "$1" "$EVENTS_URL$2" -H "Authorization: Bearer $3" \
    -H 'Content-Type: application/json' ${4:+--data-binary "$4"}; }
  T_O=$(signin "olive$SUFFIX"); T_ANN=$(signin "ann$SUFFIX"); T_BEN=$(signin "ben$SUFFIX")
  ev POST /api/events "$T_O" "{\"title\":\"Pizza and code\",\"startsAt\":\"$START\",\"location\":\"Lab 3\",\"capacity\":1}" >/dev/null
  E2=$(jget j.id < infra/out/tmp/ev.json)
  ev PATCH "/api/events/$E2" "$T_O" '{"status":"published"}' >/dev/null
  ev POST "/api/events/$E2/rsvps" "$T_ANN" >/dev/null
  ev POST "/api/events/$E2/rsvps" "$T_BEN" >/dev/null
  check "Events: Ann has the seat, Ben is waitlisted" waitlisted "$(jget j.status < infra/out/tmp/ev.json)"
  BEN_BEFORE=$(count_of "$ID_BEN")
  check "Events: Ann cancels her RSVP" 204 "$(ev DELETE "/api/events/$E2/rsvps/me" "$T_ANN")"
  check "Ben is told he got the seat" "You got a seat: Pizza and code" \
    "$(wait_count "$ID_BEN" $((BEN_BEFORE + 1)) >/dev/null; titles_of "$ID_BEN" | cut -d';' -f1)"
  check "Events: officer cancels the event" 200 "$(ev PATCH "/api/events/$E2" "$T_O" '{"status":"cancelled"}')"
  check "Ben is told it was cancelled" "Cancelled: Pizza and code" \
    "$(wait_count "$ID_BEN" $((BEN_BEFORE + 2)) >/dev/null; titles_of "$ID_BEN" | cut -d';' -f1)"
  # The event, its RSVPs and the automatic announcements belong to this run's accounts.
  "$AWS" dynamodb delete-item --table-name ClubEvents --key "{\"eventId\":{\"S\":\"$E2\"}}" >/dev/null 2>&1
  for u in "$ID_ANN" "$ID_BEN"; do
    "$AWS" dynamodb delete-item --table-name EventRsvps --key "{\"eventId\":{\"S\":\"$E2\"},\"userId\":{\"S\":\"$u\"}}" >/dev/null 2>&1
  done
  drop_event_posts "$E2"
  rm -f infra/out/tmp/ev.json
else
  echo "SKIP  end to end through Events (deploy ../club-events-service first)"
fi

sleep 3; drop_event_posts "$E1"
rm -f infra/out/tmp/bus-entry.json
cleanup_test_data
finish
