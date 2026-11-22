// Membership requests in DynamoDB.
//
// Each request stores the applicant's bcrypt hash; no account exists until an
// officer approves it. Every email is claimed once with an "EMAIL#<email>"
// item in the same table, written in the same transaction as the request, so
// the same email can never have two requests, even when sent at once.
//
// Review is one transaction: the request must still be pending and the
// reviewer must still be an active officer. Approval also creates the
// account (moving the hash to it) and writes the audit entry; if any part
// fails, nothing changes.
const crypto = require("crypto");
const { GetCommand, QueryCommand, TransactWriteCommand } = require("@aws-sdk/lib-dynamodb");
const { db } = require("../lib/aws");
const config = require("../lib/config");
const users = require("./users");
const audit = require("./audit");

class EmailTaken extends Error {}
class NotFound extends Error {}
class AlreadyDecided extends Error {}
class NotAnOfficer extends Error {}

const emailClaimKey = (emailLower) => `EMAIL#${emailLower}`;
const STATUSES = ["pending", "approved", "rejected"];

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
              requestId, fullName, email, emailLower, passwordHash,
              status: "pending", submittedAt, sourceIpHash,
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

// Oldest first, at most `limit`, with explicit fields (never the hash).
async function listByStatus(status, limit = 100) {
  const res = await db.send(new QueryCommand({
    TableName: config.tables.requests,
    IndexName: "StatusIndex",
    KeyConditionExpression: "#s = :status",
    ExpressionAttributeNames: { "#s": "status" },
    ExpressionAttributeValues: { ":status": status },
    ScanIndexForward: true,
    Limit: limit,
  }));
  return (res.Items || []).map((r) => ({
    requestId: r.requestId,
    fullName: r.fullName,
    email: r.email,
    status: r.status,
    submittedAt: r.submittedAt,
    reviewedAt: r.reviewedAt || null,
    reviewedBy: r.reviewedBy || null,
  }));
}

async function getRequest(requestId) {
  if (requestId.startsWith("EMAIL#")) return null;
  const res = await db.send(new GetCommand({ TableName: config.tables.requests, Key: { requestId } }));
  return res.Item || null;
}

// decision: "approve" | "reject". Returns { requestId, status, alreadyDecided, userId? }.
async function review(requestId, reviewerId, decision) {
  const target = decision === "approve" ? "approved" : "rejected";
  const request = await getRequest(requestId);
  if (!request) throw new NotFound();

  // The same decision again changes nothing.
  if (request.status === target) {
    return { requestId, status: target, alreadyDecided: true };
  }
  if (request.status !== "pending") throw new AlreadyDecided();

  const now = new Date().toISOString();
  const decideRequest = {
    Update: {
      TableName: config.tables.requests,
      Key: { requestId },
      UpdateExpression: "SET #s = :target, reviewedAt = :now, reviewedBy = :rev REMOVE passwordHash",
      ConditionExpression: "#s = :pending",
      ExpressionAttributeNames: { "#s": "status" },
      ExpressionAttributeValues: { ":target": target, ":now": now, ":rev": reviewerId, ":pending": "pending" },
    },
  };

  let userId = null;
  const items = [decideRequest, users.activeOfficerCheck(reviewerId)];
  if (target === "approved") {
    userId = crypto.randomUUID();
    items.push(
      {
        Put: {
          TableName: config.tables.users,
          Item: {
            userId,
            fullName: request.fullName,
            email: request.email,
            emailLower: request.emailLower,
            passwordHash: request.passwordHash,
            role: "member",
            active: true,
            failedLogins: 0,
            createdAt: now,
            requestId,
          },
          ConditionExpression: "attribute_not_exists(userId)",
        },
      },
      {
        Update: {
          TableName: config.tables.requests,
          Key: { requestId: emailClaimKey(request.emailLower) },
          UpdateExpression: "SET userId = :uid",
          ExpressionAttributeValues: { ":uid": userId },
        },
      },
      audit.entryPut({ eventType: "membership_approved", actorId: reviewerId, targetId: userId, metadata: { requestId } }),
    );
  } else {
    items.push(audit.entryPut({
      eventType: "membership_rejected",
      actorId: reviewerId,
      metadata: { requestId, applicantName: request.fullName },
    }));
  }

  try {
    await db.send(new TransactWriteCommand({ TransactItems: items }));
  } catch (err) {
    if (err.name !== "TransactionCanceledException") throw err;
    const reasons = err.CancellationReasons || [];
    if (reasons[1]?.Code === "ConditionalCheckFailed") throw new NotAnOfficer();
    if (reasons[0]?.Code === "ConditionalCheckFailed") {
      // Another officer decided first: same decision is fine, different is a conflict.
      const now2 = await getRequest(requestId);
      if (now2?.status === target) return { requestId, status: target, alreadyDecided: true };
      throw new AlreadyDecided();
    }
    throw err;
  }

  return { requestId, status: target, alreadyDecided: false, ...(userId ? { userId } : {}) };
}

module.exports = {
  countPending, createRequest, listByStatus, review, STATUSES,
  EmailTaken, NotFound, AlreadyDecided, NotAnOfficer,
};
