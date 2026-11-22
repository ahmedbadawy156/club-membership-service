#!/usr/bin/env bash
# Runs every test suite against the Floci deployment and prints a summary.
#   bash tests/run-all.sh            (after bash infra/deploy.sh)
# Full output is saved to infra/out/test-results.txt for the evidence folder.
cd "$(dirname "$0")/.."
mkdir -p infra/out
OUT=infra/out/test-results.txt
: > "$OUT"
TOTAL_PASS=0; TOTAL_FAIL=0; FAILED_SUITES=""

for suite in infra/check.sh tests/membership-requests.sh tests/officer-review.sh \
             tests/login.sh tests/role-change.sh tests/members-audit.sh tests/iam.sh; do
  echo "### $suite ($(date -u +%Y-%m-%dT%H:%M:%SZ))" >> "$OUT"
  bash "$suite" >> "$OUT" 2>&1
  line=$(grep -E '^== [0-9]+ passed, [0-9]+ failed' "$OUT" | tail -1)
  p=$(echo "$line" | awk '{print $2}'); f=$(echo "$line" | awk '{print $4}')
  TOTAL_PASS=$((TOTAL_PASS + ${p:-0})); TOTAL_FAIL=$((TOTAL_FAIL + ${f:-1}))
  [ "${f:-1}" != "0" ] && FAILED_SUITES="$FAILED_SUITES $suite"
  printf '%-32s %s\n' "$suite" "${line#== }"
  echo >> "$OUT"
done

echo "== total: $TOTAL_PASS passed, $TOTAL_FAIL failed (details in $OUT)"
[ -z "$FAILED_SUITES" ] || { echo "failed:$FAILED_SUITES"; exit 1; }
