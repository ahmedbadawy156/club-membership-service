#!/usr/bin/env bash
# Local tests for officer review:
#   GET   /membership-api/membership-requests?status=
#   PATCH /membership-api/membership-requests/:id
#
# Requires the local stack (npx supabase start). Run from the repository
# root in Git Bash:   bash tests/officer-review.sh
#
# Creates its own test officer (independent of scripts/create-officer.sh,
# so it also works when a real local officer exists) and uses only
# *@example.test addresses, removed before and after. Keys and tokens are
# never printed.

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

# jget EXPR  (reads JSON on stdin, evaluates EXPR with the parsed value as j)
jget() {
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    let j;try{j=JSON.parse(s)}catch{j=null}
    let v;try{v=eval(process.argv[1])}catch{v=undefined}
    process.stdout.write(v===undefined||v===null?"":String(v))})' "$1"
}

# call METHOD URL [curl args...] -> sets STATUS and BODY
call() {
  local method="$1" url="$2"; shift 2
  local out
  out="$(curl -s -w '\n%{http_code}' -X "$method" "$url" "$@")"
  STATUS="${out##*$'\n'}"
  BODY="${out%$'\n'*}"
}

sign_in() { # email -> prints access token or the raw error body
  curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" "${PK[@]}" \
    -H "Content-Type: application/json" \
    --data-binary "{\"email\":\"$1\",\"password\":\"$PW\"}"
}

submit() { # name email -> prints requestId
  curl -s -X POST "$FN/membership-requests" "${PK[@]}" \
    -H "Content-Type: application/json" \
    --data-binary "{\"fullName\":\"$1\",\"email\":\"$2\",\"password\":\"$PW\"}" \
    | jget 'j.requestId'
}

review() { # token requestId decision
  call PATCH "$FN/membership-requests/$2" "${PK[@]}" \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    --data-binary "{\"decision\":\"$3\"}"
}

cleanup
echo "== officer review tests (run $RUN_ID)"

# --- setup: test officer (Auth account + active officer profile)
OFFICER_EMAIL="officer-$RUN_ID@example.test"
OFFICER_ID="$(curl -s -X POST "$API_URL/auth/v1/admin/users" \
  -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SECRET_KEY" \
  -H "Content-Type: application/json" \
  --data-binary "{\"email\":\"$OFFICER_EMAIL\",\"password\":\"$PW\",\"email_confirm\":true,\"app_metadata\":{\"role\":\"officer\"}}" \
  | jget 'j.id')"
sql "insert into public.profiles (user_id, full_name, email, role, active)
     values ('$OFFICER_ID', 'Test Officer', '$OFFICER_EMAIL', 'officer', true);" >/dev/null
OFFICER_TOKEN="$(sign_in "$OFFICER_EMAIL" | jget 'j.access_token')"
check "setup: officer signed in" yes "$([ -n "$OFFICER_TOKEN" ] && echo yes || echo no)"
OFF=(-H "Authorization: Bearer $OFFICER_TOKEN")

# --- setup: three applicants
EMAIL_A="appa-$RUN_ID@example.test"
EMAIL_B="appb-$RUN_ID@example.test"
EMAIL_C="appc-$RUN_ID@example.test"
REQ_A="$(submit "Applicant A" "$EMAIL_A")"
REQ_B="$(submit "Applicant B" "$EMAIL_B")"
REQ_C="$(submit "Applicant C" "$EMAIL_C")"
check "setup: three requests submitted" yes \
  "$([ -n "$REQ_A" ] && [ -n "$REQ_B" ] && [ -n "$REQ_C" ] && echo yes || echo no)"

# --- GET list
call GET "$FN/membership-requests" "${PK[@]}" "${OFF[@]}"
check "officer lists pending" 200 "$STATUS" "$BODY"
check "list contains the three test requests" 3 \
  "$(printf '%s' "$BODY" | jget "j.requests.filter(r=>r.email.endsWith('-$RUN_ID@example.test')).length")"
check "list returns only the documented fields" \
  "email,fullName,requestId,reviewedAt,reviewedBy,status,submittedAt" \
  "$(printf '%s' "$BODY" | jget 'Object.keys(j.requests[0]).sort().join(",")')"

call GET "$FN/membership-requests" "${PK[@]}"
check "list with publishable key only" 401 "$STATUS" "$BODY"

call GET "$FN/membership-requests?status=bogus" "${PK[@]}" "${OFF[@]}"
check "list with invalid status" 400 "$STATUS" "$BODY"

# --- approve A
review "$OFFICER_TOKEN" "$REQ_A" approve
check "approve request A" 200 "$STATUS" "$BODY"
check "approve A: alreadyDecided false" false "$(printf '%s' "$BODY" | jget 'j.alreadyDecided')"

A_SIGNIN="$(sign_in "$EMAIL_A")"
MEMBER_TOKEN="$(printf '%s' "$A_SIGNIN" | jget 'j.access_token')"
check "approved applicant can sign in" yes "$([ -n "$MEMBER_TOKEN" ] && echo yes || echo no)" "$A_SIGNIN"
check "approved applicant token role claim" member \
  "$(node -e 'try{console.log(JSON.parse(Buffer.from(process.argv[1].split(".")[1],"base64url")).app_metadata.role)}catch{console.log("none")}' "$MEMBER_TOKEN")"
check "db: A profile active, request approved by officer" "t|approved|t" \
  "$(sql "select p.active, r.status, r.reviewed_by = '$OFFICER_ID'
          from public.profiles p join public.membership_requests r using (user_id)
          where p.email = '$EMAIL_A';")"

AUDIT_BEFORE="$(sql "select count(*) from public.audit_log where actor_id = '$OFFICER_ID';")"
review "$OFFICER_TOKEN" "$REQ_A" approve
check "approve A again" 200 "$STATUS" "$BODY"
check "approve A again: alreadyDecided true" true "$(printf '%s' "$BODY" | jget 'j.alreadyDecided')"
check "approve A again: no new audit row" "$AUDIT_BEFORE" \
  "$(sql "select count(*) from public.audit_log where actor_id = '$OFFICER_ID';")"

review "$OFFICER_TOKEN" "$REQ_A" reject
check "reject A after approval" 409 "$STATUS" "$BODY"

# --- reject B
review "$OFFICER_TOKEN" "$REQ_B" reject
check "reject request B" 200 "$STATUS" "$BODY"
check "rejected applicant still banned" user_banned \
  "$(sign_in "$EMAIL_B" | jget 'j.error_code')"
check "db: B profile inactive" f \
  "$(sql "select active from public.profiles where email = '$EMAIL_B';")"

check "audit log: approved A and rejected B by officer" \
  "membership_approved:$EMAIL_A,membership_rejected:$EMAIL_B" \
  "$(sql "select string_agg(a.event_type || ':' || p.email, ',' order by a.event_type)
          from public.audit_log a join public.profiles p on p.user_id = a.target_id
          where a.actor_id = '$OFFICER_ID';")"

# --- members cannot use officer routes
MEM=(-H "Authorization: Bearer $MEMBER_TOKEN")
call GET "$FN/membership-requests" "${PK[@]}" "${MEM[@]}"
check "member token: list" 403 "$STATUS" "$BODY"
review "$MEMBER_TOKEN" "$REQ_C" approve
check "member token: approve C" 403 "$STATUS" "$BODY"
check "C still pending after member attempt" pending \
  "$(sql "select status from public.membership_requests where request_id = '$REQ_C';")"

# --- input errors
review "$OFFICER_TOKEN" "not-a-uuid" approve
check "PATCH with invalid id" 400 "$STATUS" "$BODY"
review "$OFFICER_TOKEN" "00000000-0000-4000-8000-000000000000" approve
check "PATCH unknown request" 404 "$STATUS" "$BODY"
review "$OFFICER_TOKEN" "$REQ_C" maybe
check "PATCH with invalid decision" 400 "$STATUS" "$BODY"
call GET "$FN/membership-requests/$REQ_C" "${PK[@]}" "${OFF[@]}"
check "GET on a single request" 405 "$STATUS" "$BODY"

# --- deactivated officer loses access at once (token still valid)
sql "update public.profiles set active = false where user_id = '$OFFICER_ID';" >/dev/null
call GET "$FN/membership-requests" "${PK[@]}" "${OFF[@]}"
check "deactivated officer: list" 403 "$STATUS" "$BODY"
review "$OFFICER_TOKEN" "$REQ_C" approve
check "deactivated officer: approve C" 403 "$STATUS" "$BODY"
sql "update public.profiles set active = true where user_id = '$OFFICER_ID';" >/dev/null

# --- approved list
call GET "$FN/membership-requests?status=approved" "${PK[@]}" "${OFF[@]}"
check "approved list shows A reviewed by the officer" "$OFFICER_ID" \
  "$(printf '%s' "$BODY" | jget "(j.requests.find(r=>r.email==='$EMAIL_A')||{}).reviewedBy")"

# --- direct database access with the publishable key
call POST "$API_URL/rest/v1/rpc/review_membership_request" "${PK[@]}" \
  -H "Content-Type: application/json" \
  --data-binary "{\"p_request_id\":\"$REQ_C\",\"p_reviewer_id\":\"$OFFICER_ID\",\"p_decision\":\"approve\"}"
check "direct RPC review_membership_request refused" 401 "$STATUS"

cleanup
echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
