// Membership requests in DynamoDB.
//
// Each request stores the applicant's bcrypt hash; no account exists until an
// officer approves it. Every email is claimed once with an "EMAIL#<email>"
// item in the same table, written in the same transaction as the request, so
// the same email can never have two requests, even when sent at once.
const crypto = require("crypto");
const { QueryCommand, TransactWriteCommand } = require("@aws-sdk/lib-dynamodb");
const { db } = require("../lib/aws");
const config = require("../lib/config");

class EmailTaken extends Error {}

const emailClaimKey = (emailLower) => `EMAIL#${emailLower}`;

async function countPending() {
  let count = 0;
  let ExclusiveStartKey;
  do {
    const res = await db.send(new QueryCommand({
      TableName: config.tables.requests,
      IndexName: "StatusIndex",
      KeyConditionExpression: "#s = :pending",
      ExpressionAttributeNames: { "#s": "status" },
      ExpressionAttributeValues: { ":pending": "pending" },
      Select: "COUNT",
      ExclusiveStartKey,
    }));
    count += res.Count || 0;
    ExclusiveStartKey = res.LastEvaluatedKey;
  } while (ExclusiveStartKey);
  return count;
}

async function createRequest({ fullName, email, passwordHash, sourceIpHash }) {
  const requestId = crypto.randomUUID();
  const emailLower = email.toLowerCase();
  const submittedAt = new Date().toISOString();

  try {
    await db.send(new TransactWriteCommand({
      TransactItems: [
        {
          Put: {
            TableName: config.tables.requests,
            Item: { requestId: emailClaimKey(emailLower), claimFor: requestId, createdAt: submittedAt },
            ConditionExpression: "attribute_not_exists(requestId)",
          },
        },
        {
          Put: {
            TableName: config.tables.requests,
            Item: {
              requestId,
              fullName,
              email,
              emailLower,
              passwordHash,
              status: "pending",
              submittedAt,
              sourceIpHash,
            },
            ConditionExpression: "attribute_not_exists(requestId)",
          },
        },
      ],
    }));
  } catch (err) {
    const reasons = err.CancellationReasons || [];
    if (err.name === "TransactionCanceledException" && reasons[0]?.Code === "ConditionalCheckFailed") {
      throw new EmailTaken();
    }
    throw err;
  }

  return { requestId, status: "pending" };
}

module.exports = { countPending, createRequest, EmailTaken };
