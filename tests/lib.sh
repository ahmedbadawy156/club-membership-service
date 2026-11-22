# Shared helpers for the test scripts. Sourced after infra/config.sh.

PASS=0
FAIL=0

check() { # NAME EXPECTED ACTUAL [DETAIL]
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-55s %s\n' "$1" "$3"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-55s expected %s, got %s  %s\n' "$1" "$2" "$3" "${4:-}"
  fi
}

finish() {
  echo "== $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}

# jget EXPR: evaluate EXPR on JSON from stdin (as j); prints "" if missing.
jget() {
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    let j;try{j=JSON.parse(s)}catch{j=null}
    let v;try{v=eval(process.argv[1])}catch{v=undefined}
    process.stdout.write(v===undefined||v===null?"":String(v))})' "$1"
}
jq_keys() { jget 'Object.keys(j).sort().join(",")'; }

# Delete every item whose key matches a filter, using the admin CLI keys.
_delete_where() { # TABLE KEYATTR FILTER VALUES_JSON
  "$AWS" dynamodb scan --table-name "$1" --projection-expression "$2" \
    --filter-expression "$3" --expression-attribute-values "$4" \
    --query "Items[].$2.S" --output text 2>/dev/null | tr '\t' '\n' | sed 's/\r$//' |
  while read -r k; do
    [ -z "$k" ] || [ "$k" = "None" ] && continue
    "$AWS" dynamodb delete-item --table-name "$1" --key "{\"$2\":{\"S\":\"$k\"}}" >/dev/null
  done
}

reset_rate_limits() {
  "$AWS" dynamodb scan --table-name RateLimits --projection-expression limitKey \
    --query 'Items[].limitKey.S' --output text 2>/dev/null | tr '\t' '\n' | sed 's/\r$//' |
  while read -r k; do
    [ -z "$k" ] || [ "$k" = "None" ] && continue
    "$AWS" dynamodb delete-item --table-name RateLimits --key "{\"limitKey\":{\"S\":\"$k\"}}" >/dev/null
  done
}

# Remove all *@example.test requests, email claims and users, and the counters.
cleanup_test_data() {
  local v='{":d":{"S":"@example.test"}}'
  _delete_where MembershipRequests requestId 'contains(emailLower, :d) OR contains(requestId, :d)' "$v"
  _delete_where ClubUsers userId 'contains(emailLower, :d)' "$v"
  reset_rate_limits
}
