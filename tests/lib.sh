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

# Test data helpers (admin keys, see tests/helpers.js).
helper() { node tests/helpers.js "$@"; }
reset_rate_limits() { helper reset-limits; }
# Remove all *@example.test requests, email claims, users and their audit
# entries, clear the counters and recount the officers.
cleanup_test_data() { helper cleanup; }
