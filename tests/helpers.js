// Test helpers that use the admin "floci" profile directly (not the API).
//   node tests/helpers.js cleanup              remove *@example.test data
//   node tests/helpers.js reset-limits         clear rate-limit counters
//   node tests/helpers.js make-officer NAME EMAIL PASSWORD   -> prints userId
//   node tests/helpers.js token USERID ROLE [valid|expired|wrongkey|none|hs256]
//   node tests/helpers.js set-user USERID FIELD JSONVALUE
//   node tests/helpers.js audit-fill COUNT TARGETID   (login_failure entries, same timestamp)
//   node tests/helpers.js isolate-officers     officer counter = test officers only (cleanup restores it)
// Tokens are minted with the service's real private key (read from Secrets
// Manager) only so tests can act before login exists, and to build attacks.
const path = require("path");
const crypto = require("crypto");
process.env.AWS_PROFILE ||= "floci";
process.env.AWS_REGION ||= "us-east-1";
process.env.AWS_ENDPOINT_URL ||= "http://localhost:4566";

const req = (m) => require(path.join(__dirname, "..", "backend", "node_modules", m));
const { DynamoDBClient } = req("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, ScanCommand, DeleteCommand, PutCommand, UpdateCommand } = req("@aws-sdk/lib-dynamodb");
const { SecretsManagerClient, GetSecretValueCommand } = req("@aws-sdk/client-secrets-manager");
const jwt = req("jsonwebtoken");
const bcrypt = req("bcryptjs");

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TEST = "@example.test";

async function scanAll(TableName) {
  const items = [];
  let ExclusiveStartKey;
  do {
    const r = await db.send(new ScanCommand({ TableName, ExclusiveStartKey }));
    items.push(...(r.Items || []));
    ExclusiveStartKey = r.LastEvaluatedKey;
  } while (ExclusiveStartKey);
  return items;
}

async function resetLimits() {
  for (const it of await scanAll("RateLimits")) {
    await db.send(new DeleteCommand({ TableName: "RateLimits", Key: { limitKey: it.limitKey } }));
  }
}

// testOnly: count only *@example.test officers. role-change.sh uses this so
// the last-officer rule can be tested on a Floci that also holds real
// officer accounts; cleanup always restores the real count.
async function recountOfficers(testOnly = false) {
  const users = await scanAll("ClubUsers");
  const count = users.filter((u) => u.role === "officer" && u.active === true && !u.userId.startsWith("META#")
    && (!testOnly || (u.emailLower || "").includes(TEST))).length;
  await db.send(new PutCommand({ TableName: "ClubUsers", Item: { userId: "META#officers", count } }));
  return count;
}

async function cleanup() {
  const users = (await scanAll("ClubUsers")).filter((u) => (u.emailLower || "").includes(TEST));
  const requests = (await scanAll("MembershipRequests"))
    .filter((r) => (r.emailLower || "").includes(TEST) || r.requestId.includes(TEST));
  const userIds = new Set(users.map((u) => u.userId));
  const requestIds = new Set(requests.map((r) => r.requestId));
  for (const a of await scanAll("AuditLog")) {
    if (userIds.has(a.actorId) || userIds.has(a.targetId) || requestIds.has(a.metadata?.requestId)) {
      await db.send(new DeleteCommand({ TableName: "AuditLog", Key: { logId: a.logId } }));
    }
  }
  // Notices for test accounts, and for the fixed test ids the other
  // services' tests use (aaaaaaaa-0000-4000-8000-...).
  for (const n of await scanAll("MemberNotifications").catch(() => [])) {
    if (userIds.has(n.userId) || n.userId.startsWith("aaaaaaaa-0000-4000-8000-")) {
      await db.send(new DeleteCommand({ TableName: "MemberNotifications", Key: { userId: n.userId, sortKey: n.sortKey } }));
    }
  }
  for (const u of users) await db.send(new DeleteCommand({ TableName: "ClubUsers", Key: { userId: u.userId } }));
  for (const r of requests) await db.send(new DeleteCommand({ TableName: "MembershipRequests", Key: { requestId: r.requestId } }));
  await resetLimits();
  await recountOfficers();
}

async function makeOfficer(fullName, email, password) {
  const userId = crypto.randomUUID();
  const emailLower = email.toLowerCase();
  await db.send(new PutCommand({ TableName: "MembershipRequests", Item: { requestId: `EMAIL#${emailLower}`, claimFor: "test", userId } }));
  await db.send(new PutCommand({
    TableName: "ClubUsers",
    Item: {
      userId, fullName, email, emailLower, passwordHash: await bcrypt.hash(password, 10),
      role: "officer", active: true, failedLogins: 0, createdAt: new Date().toISOString(),
    },
  }));
  await recountOfficers();
  return userId;
}

async function token(userId, role, variant = "valid") {
  const s = JSON.parse((await new SecretsManagerClient({}).send(new GetSecretValueCommand({ SecretId: "club-membership/secrets" }))).SecretString);
  const claims = { role, name: "Test User" };
  const opts = { subject: userId, issuer: "club-membership", audience: "campus-club" };
  switch (variant) {
    case "valid": return jwt.sign(claims, s.jwtPrivateKey, { ...opts, algorithm: "RS256", expiresIn: 900 });
    case "expired": return jwt.sign({ ...claims, exp: Math.floor(Date.now() / 1000) - 60 }, s.jwtPrivateKey, { ...opts, algorithm: "RS256" });
    case "wrongkey": {
      const { privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
      return jwt.sign(claims, privateKey, { ...opts, algorithm: "RS256", expiresIn: 900 });
    }
    case "none": {
      const b = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
      const now = Math.floor(Date.now() / 1000);
      return `${b({ alg: "none", typ: "JWT" })}.${b({ ...claims, sub: userId, iss: opts.issuer, aud: opts.audience, iat: now, exp: now + 900 })}.`;
    }
    case "hs256": {
      // Classic attack: sign with HS256 using the PUBLIC key as the secret.
      const b = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
      const now = Math.floor(Date.now() / 1000);
      const head = `${b({ alg: "HS256", typ: "JWT" })}.${b({ ...claims, sub: userId, iss: opts.issuer, aud: opts.audience, iat: now, exp: now + 900 })}`;
      return `${head}.${crypto.createHmac("sha256", s.jwtPublicKey).update(head).digest("base64url")}`;
    }
    default: throw new Error("unknown variant");
  }
}

async function setUser(userId, field, value) {
  await db.send(new UpdateCommand({
    TableName: "ClubUsers", Key: { userId },
    UpdateExpression: "SET #f = :v", ExpressionAttributeNames: { "#f": field }, ExpressionAttributeValues: { ":v": JSON.parse(value) },
  }));
  if (field === "role" || field === "active") await recountOfficers();
}

async function auditFill(count, targetId) {
  const createdAt = new Date().toISOString();
  for (let i = 0; i < Number(count); i += 1) {
    const logId = crypto.randomUUID();
    await db.send(new PutCommand({
      TableName: "AuditLog",
      Item: { logId, feed: "audit", eventType: "login_failure", sortKey: `${createdAt}#${logId}`, createdAt, actorId: null, targetId, metadata: {} },
    }));
  }
}

(async () => {
  const [cmd, ...a] = process.argv.slice(2);
  if (cmd === "cleanup") await cleanup();
  else if (cmd === "reset-limits") await resetLimits();
  else if (cmd === "make-officer") process.stdout.write(await makeOfficer(a[0], a[1], a[2]));
  else if (cmd === "token") process.stdout.write(await token(a[0], a[1], a[2]));
  else if (cmd === "set-user") await setUser(a[0], a[1], a[2]);
  else if (cmd === "audit-fill") await auditFill(a[0], a[1]);
  else if (cmd === "isolate-officers") process.stdout.write(String(await recountOfficers(true)));
  else throw new Error(`unknown command ${cmd}`);
})().catch((e) => { console.error(e.message); process.exit(1); });
