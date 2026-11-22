#!/usr/bin/env bash
# Least-privilege test for the Membership function's IAM role (threat 9).
# Needs Floci with IAM enforcement on (infra/floci/docker-compose.yml).
#   bash tests/iam.sh
# Deploys tests/iam-probe as a temporary function with the SAME role, runs it,
# then deletes it and anything it wrote.
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh
source tests/lib.sh
PROBE=club-membership-iam-probe
mkdir -p infra/out/tmp

echo "== IAM least-privilege test for role $ROLE"

check "Floci IAM enforcement is on" true "$(docker exec floci printenv FLOCI_SERVICES_IAM_ENFORCEMENT_ENABLED 2>/dev/null)"
check "admin keys cannot assume the function's role" denied \
  "$("$AWS" sts assume-role --role-arn "arn:aws:iam::$ACCOUNT:role/$ROLE" --role-session-name t >/dev/null 2>&1 && echo allowed || echo denied)"

node -e '
const fs=require("fs"),zlib=require("zlib");const data=fs.readFileSync("tests/iam-probe/index.js");
const crcT=Array.from({length:256},(_,n)=>{let c=n;for(let k=0;k<8;k++)c=c&1?0xedb88320^(c>>>1):c>>>1;return c>>>0});
const crc=(b)=>{let c=0xffffffff;for(const x of b)c=crcT[(c^x)&0xff]^(c>>>8);return(c^0xffffffff)>>>0};
const name=Buffer.from("index.js"),packed=zlib.deflateRawSync(data),cr=crc(data);
const l=Buffer.alloc(30);l.writeUInt32LE(0x04034b50,0);l.writeUInt16LE(20,4);l.writeUInt16LE(8,8);l.writeUInt32LE(cr,14);l.writeUInt32LE(packed.length,18);l.writeUInt32LE(data.length,22);l.writeUInt16LE(name.length,26);
const c=Buffer.alloc(46);c.writeUInt32LE(0x02014b50,0);c.writeUInt16LE(0x0314,4);c.writeUInt16LE(20,6);c.writeUInt16LE(8,10);c.writeUInt32LE(cr,16);c.writeUInt32LE(packed.length,20);c.writeUInt32LE(data.length,24);c.writeUInt16LE(name.length,28);c.writeUInt32LE((0o100644<<16)>>>0,38);
const e=Buffer.alloc(22);e.writeUInt32LE(0x06054b50,0);e.writeUInt16LE(1,8);e.writeUInt16LE(1,10);e.writeUInt32LE(46+name.length,12);e.writeUInt32LE(30+name.length+packed.length,16);
fs.writeFileSync("infra/out/tmp/iam-probe.zip",Buffer.concat([l,name,packed,c,name,e]));'

"$AWS" lambda delete-function --function-name "$PROBE" >/dev/null 2>&1
"$AWS" lambda create-function --function-name "$PROBE" --runtime nodejs24.x --handler index.handler \
  --role "arn:aws:iam::$ACCOUNT:role/$ROLE" --zip-file fileb://infra/out/tmp/iam-probe.zip --timeout 30 >/dev/null
"$AWS" lambda wait function-active-v2 --function-name "$PROBE"
"$AWS" lambda invoke --function-name "$PROBE" --cli-read-timeout 300 infra/out/tmp/iam-probe.json >/dev/null
R=$(cat infra/out/tmp/iam-probe.json)

for pair in "scan ClubUsers:allowed" "read own secret:allowed" "put AuditLog:allowed" \
            "update AuditLog:denied" "delete AuditLog:denied" "scan RateLimits:denied" "list tables:denied" "create a secret:denied"; do
  op=${pair%%:*}; want=${pair##*:}
  check "role: $op" "$want" "$(printf '%s' "$R" | jget "j[\"$op\"]")"
done

# Clean up the probe and the audit entry it wrote.
"$AWS" lambda delete-function --function-name "$PROBE" >/dev/null 2>&1
"$AWS" logs delete-log-group --log-group-name "/aws/lambda/$PROBE" >/dev/null 2>&1
"$AWS" dynamodb delete-item --table-name AuditLog --key '{"logId":{"S":"iam-probe"}}' >/dev/null 2>&1
"$AWS" secretsmanager delete-secret --secret-id iam-probe-should-fail --force-delete-without-recovery >/dev/null 2>&1
rm -f infra/out/tmp/iam-probe.*
finish
