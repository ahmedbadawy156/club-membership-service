#!/usr/bin/env bash
# Create the club's first officer in the Floci tables. Works only while no
# officer exists.
#   bash infra/create-officer.sh
# Asks for name, email and password (hidden). For automated local tests,
# OFFICER_NAME, OFFICER_EMAIL and OFFICER_PASSWORD can be set instead.
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh

[ -d backend/node_modules ] || (cd backend && npm install --no-audit --no-fund --loglevel=error)

NAME="${OFFICER_NAME:-}"
EMAIL="${OFFICER_EMAIL:-}"
PASSWORD="${OFFICER_PASSWORD:-}"
[ -n "$NAME" ] || read -r -p "Officer full name: " NAME
[ -n "$EMAIL" ] || read -r -p "Officer email: " EMAIL
if [ -z "$PASSWORD" ]; then
  read -r -s -p "Password (8 to 72 characters): " PASSWORD; echo
  read -r -s -p "Repeat password: " PASSWORD2; echo
  [ "$PASSWORD" = "$PASSWORD2" ] || { echo "Passwords do not match." >&2; exit 1; }
  unset PASSWORD2
fi

# The admin "floci" profile writes the tables directly (not through the API).
OFFICER_NAME="$NAME" OFFICER_EMAIL="$EMAIL" OFFICER_PASSWORD="$PASSWORD" \
AWS_REGION="$REGION" AWS_ENDPOINT_URL=http://localhost:4566 \
  node backend/scripts/create-officer.js
