// Login with a per-account lockout.
//
// Rules: 5 failed logins lock the account for 15 minutes. Each attempt is
// counted BEFORE the password is checked, with an atomic DynamoDB update that
// only succeeds while fewer than 5 attempts are counted, so a burst of
// simultaneous guesses cannot get more than 5 past the counter. A successful
// login resets the counter. Every failure for an existing account writes
// login_failure; the lock writes account_locked exactly once.
const { GetCommand, QueryCommand, UpdateCommand, TransactWriteCommand } = require("@aws-sdk/lib-dynamodb");
const { db } = require("../lib/aws");
const config = require("../lib/config");
const { checkPassword } = require("../lib/passwords");
const audit = require("./audit");

const MAX_FAILURES = 5;
const LOCK_SECONDS = 15 * 60;

// Compared against for unknown emails, so they take as long as known ones.
const DUMMY_HASH = "$2b$10$ZHPFzx5IPNt4aMbNA4sExOztgyqI3iYjLGaAVJGn62f15To/0wgMa";

const nowSeconds = () => Math.floor(Date.now() / 1000);
const isConditionFailure = (err) => err.name === "ConditionalCheckFailedException";

async function findByEmail(email) {
  const res = await db.send(new QueryCommand({
    TableName: config.tables.users,
    IndexName: "EmailIndex",
    KeyConditionExpression: "emailLower = :e",
    ExpressionAttributeValues: { ":e": email.toLowerCase() },
    Limit: 1,
  }));
  return res.Items?.[0] || null;
}

// Lock the account if it is not locked yet; returns true for the call that
// locked it. The lock and its audit entry are written together.
async function lockIfNeeded(userId) {
  const now = nowSeconds();
  const lockedUntil = now + LOCK_SECONDS;
  try {
    await db.send(new TransactWriteCommand({
      TransactItems: [
        {
          Update: {
            TableName: config.tables.users,
            Key: { userId },
            UpdateExpression: "SET lockedUntil = :until",
            ConditionExpression: "attribute_not_exists(lockedUntil) OR lockedUntil <= :now",
            ExpressionAttributeValues: { ":until": lockedUntil, ":now": now },
          },
        },
        audit.entryPut({
          eventType: "account_locked",
          targetId: userId,
          metadata: { lockedUntil: new Date(lockedUntil * 1000).toISOString() },
        }),
      ],
    }));
    return true;
  } catch (err) {
    if (err.name === "TransactionCanceledException") return false; // already locked
    throw err;
  }
}

// Count this attempt before checking the password.
// Returns { allowed: true } or { allowed: false, retryAfter }.
async function startAttempt(user) {
  const now = nowSeconds();

  if (user.lockedUntil && user.lockedUntil > now) {
    return { allowed: false, retryAfter: user.lockedUntil - now };
  }

  // An expired lock starts a fresh count (only if nobody else did meanwhile).
  if (user.lockedUntil) {
    try {
      await db.send(new UpdateCommand({
        TableName: config.tables.users,
        Key: { userId: user.userId },
        UpdateExpression: "SET failedLogins = :zero REMOVE lockedUntil",
        ConditionExpression: "lockedUntil = :old",
        ExpressionAttributeValues: { ":zero": 0, ":old": user.lockedUntil },
      }));
    } catch (err) {
      if (!isConditionFailure(err)) throw err;
    }
  }

  try {
    await db.send(new UpdateCommand({
      TableName: config.tables.users,
      Key: { userId: user.userId },
      UpdateExpression: "ADD failedLogins :one",
      ConditionExpression:
        "(attribute_not_exists(lockedUntil) OR lockedUntil <= :now) AND " +
        "(attribute_not_exists(failedLogins) OR failedLogins < :max)",
      ExpressionAttributeValues: { ":one": 1, ":now": now, ":max": MAX_FAILURES },
    }));
    return { allowed: true };
  } catch (err) {
    if (!isConditionFailure(err)) throw err;
    // Locked meanwhile, or simultaneous attempts used every slot: lock now.
    await lockIfNeeded(user.userId);
    return { allowed: false, retryAfter: LOCK_SECONDS };
  }
}

async function recordSuccess(userId) {
  await db.send(new UpdateCommand({
    TableName: config.tables.users,
    Key: { userId },
    UpdateExpression: "SET failedLogins = :zero REMOVE lockedUntil",
    ExpressionAttributeValues: { ":zero": 0 },
  }));
}

// Write login_failure, and lock the account once the count reaches the limit.
async function recordFailure(userId) {
  await db.send(new TransactWriteCommand({
    TransactItems: [audit.entryPut({ eventType: "login_failure", targetId: userId })],
  }));
  const res = await db.send(new GetCommand({
    TableName: config.tables.users, Key: { userId }, ConsistentRead: true,
  }));
  if ((res.Item?.failedLogins || 0) >= MAX_FAILURES) await lockIfNeeded(userId);
}

// Returns { ok: true, user } | { ok: false, reason: "invalid" } |
//         { ok: false, reason: "locked", retryAfter }
async function attemptLogin(email, password) {
  const user = await findByEmail(email);
  if (!user) {
    await checkPassword(password, DUMMY_HASH);
    return { ok: false, reason: "invalid" };
  }

  const start = await startAttempt(user);
  if (!start.allowed) return { ok: false, reason: "locked", retryAfter: start.retryAfter };

  const passwordOk = await checkPassword(password, user.passwordHash);
  if (passwordOk && user.active === true) {
    await recordSuccess(user.userId);
    return { ok: true, user };
  }
  await recordFailure(user.userId);
  return { ok: false, reason: "invalid" };
}

module.exports = { attemptLogin, MAX_FAILURES, LOCK_SECONDS };
