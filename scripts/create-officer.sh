#!/usr/bin/env bash
# Create the first club officer. Works only while no officer exists.
#
# Local stack (default):   bash scripts/create-officer.sh
#   Reads the API URL and secret key from `npx supabase status`.
#
# Prompts for name, email and password (password input is hidden). For
# automated local tests only, OFFICER_NAME, OFFICER_EMAIL and
# OFFICER_PASSWORD can be set instead of typing.
#
# Steps: refuse early if an officer exists -> create the Auth account
# with app_metadata.role = "officer" -> call bootstrap_first_officer.
# If the database step refuses, the new Auth account is deleted again.
#
# Never prints the secret key or the password. JSON is built with Node
# and sent on stdin so the password does not appear in process arguments.

set -euo pipefail

eval "$(npx supabase status -o env 2>/dev/null \
  | grep -E '^(API_URL|SECRET_KEY)=')" || true
if [ -z "${API_URL:-}" ] || [ -z "${SECRET_KEY:-}" ]; then
  echo "Local stack is not running (npx supabase start)." >&2
  exit 2
fi
echo "Target: $API_URL (local stack)"

# api METHOD PATH [stdin JSON] -> prints body, then a last line with status
api() {
  curl -s -w '\n%{http_code}' -X "$1" "$API_URL$2" \
    -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SECRET_KEY" \
    -H "Content-Type: application/json" --data-binary @-
}
status_of() { printf '%s' "${1##*$'\n'}"; }
body_of() { printf '%s' "${1%$'\n'*}"; }
json_field() { # json_field FIELD  (reads JSON on stdin)
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    try{const v=JSON.parse(s)[process.argv[1]];process.stdout.write(v==null?"":String(v))}
    catch{process.stdout.write("")}})' "$1"
}

# 1. Refuse early if an officer already exists.
RES="$(printf '' | curl -s -w '\n%{http_code}' \
  "$API_URL/rest/v1/profiles?select=user_id&role=eq.officer&limit=1" \
  -H "apikey: $SECRET_KEY" -H "Authorization: Bearer $SECRET_KEY")"
if [ "$(status_of "$RES")" != "200" ]; then
  echo "Could not check existing officers (HTTP $(status_of "$RES"))." >&2
  exit 1
fi
if [ "$(body_of "$RES")" != "[]" ]; then
  echo "An officer already exists. Use the role endpoints instead." >&2
  exit 1
fi

# 2. Collect details.
NAME="${OFFICER_NAME:-}"
EMAIL="${OFFICER_EMAIL:-}"
PASSWORD="${OFFICER_PASSWORD:-}"
[ -n "$NAME" ] || read -r -p "Officer full name: " NAME
[ -n "$EMAIL" ] || read -r -p "Officer email: " EMAIL
if [ -z "$PASSWORD" ]; then
  read -r -s -p "Password (8 to 72 characters): " PASSWORD; echo
  read -r -s -p "Repeat password: " PASSWORD2; echo
  if [ "$PASSWORD" != "$PASSWORD2" ]; then
    echo "Passwords do not match." >&2
    exit 1
  fi
fi

NAME="$(printf '%s' "$NAME" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
EMAIL="$(printf '%s' "$EMAIL" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
if [ "${#NAME}" -lt 2 ] || [ "${#NAME}" -gt 100 ]; then
  echo "Name must be 2 to 100 characters." >&2; exit 1
fi
if ! printf '%s' "$EMAIL" | grep -Eq '^[^@]+@[^@]+\.[^@]+$'; then
  echo "Email address is not valid." >&2; exit 1
fi
PW_BYTES="$(printf '%s' "$PASSWORD" | wc -c | tr -d ' ')"
if [ "$PW_BYTES" -lt 8 ] || [ "$PW_BYTES" -gt 72 ]; then
  echo "Password must be 8 to 72 characters." >&2; exit 1
fi

# 3. Create the Auth account.
RES="$(NAME="$NAME" EMAIL="$EMAIL" PASSWORD="$PASSWORD" node -e '
  process.stdout.write(JSON.stringify({
    email: process.env.EMAIL,
    password: process.env.PASSWORD,
    email_confirm: true,
    app_metadata: { role: "officer" },
  }))' | api POST /auth/v1/admin/users)"
unset PASSWORD PASSWORD2
if [ "$(status_of "$RES")" != "200" ]; then
  CODE="$(body_of "$RES" | json_field error_code)"
  echo "Creating the Auth account failed (HTTP $(status_of "$RES"), ${CODE:-unknown})." >&2
  exit 1
fi
USER_ID="$(body_of "$RES" | json_field id)"

# 4. Create the officer profile (refuses if an officer appeared meanwhile).
RES="$(USER_ID="$USER_ID" NAME="$NAME" EMAIL="$EMAIL" node -e '
  process.stdout.write(JSON.stringify({
    p_user_id: process.env.USER_ID,
    p_full_name: process.env.NAME,
    p_email: process.env.EMAIL,
  }))' | api POST /rest/v1/rpc/bootstrap_first_officer)"
STATUS="$(status_of "$RES")"
if [ "$STATUS" != "200" ] && [ "$STATUS" != "204" ]; then
  CODE="$(body_of "$RES" | json_field code)"
  printf '' | api DELETE "/auth/v1/admin/users/$USER_ID" >/dev/null || true
  if [ "$CODE" = "MB001" ]; then
    echo "An officer already exists. The new Auth account was removed." >&2
  else
    echo "Creating the officer profile failed (HTTP $STATUS, ${CODE:-unknown}). The new Auth account was removed." >&2
  fi
  exit 1
fi

echo "Officer created: $EMAIL (user id $USER_ID)"
