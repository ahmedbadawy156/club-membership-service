// Fixed-window counters in the RateLimits table.
//
// One atomic UpdateItem per attempt: it adds 1 only while the count is below
// the limit, so simultaneous requests cannot slip past it. Refused attempts
// are not counted. Items expire through DynamoDB TTL on expiresAt.
const { UpdateCommand } = require("@aws-sdk/lib-dynamodb");
const { db } = require("../lib/aws");
const config = require("../lib/config");

// Returns { allowed: true } or { allowed: false, retryAfter: seconds }.
async function takeSlot(name, subject, max, windowSeconds) {
  const now = Math.floor(Date.now() / 1000);
  const windowStart = now - (now % windowSeconds);
  const windowEnd = windowStart + windowSeconds;
  try {
    await db.send(new UpdateCommand({
      TableName: config.tables.rateLimits,
      Key: { limitKey: `${name}#${subject}#${windowStart}` },
      UpdateExpression: "ADD hits :one SET expiresAt = if_not_exists(expiresAt, :exp)",
      ConditionExpression: "attribute_not_exists(hits) OR hits < :max",
      ExpressionAttributeValues: { ":one": 1, ":max": max, ":exp": windowEnd + 60 },
    }));
    return { allowed: true };
  } catch (err) {
    if (err.name === "ConditionalCheckFailedException") {
      return { allowed: false, retryAfter: Math.max(1, windowEnd - now) };
    }
    throw err;
  }
}

module.exports = { takeSlot };
