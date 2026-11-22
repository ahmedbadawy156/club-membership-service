// Role changes between "member" and "officer".
//
// One transaction: change the target's role (only if it still has the old
// role and is active), check the actor is still an active officer, adjust the
// officer counter (a demotion only while more than one officer remains), and
// write role_changed with the old and new role. If any part fails, nothing
// changes. Two officers demoting each other at the same moment cannot both
// succeed, because both transactions need the same counter item.
const { TransactWriteCommand } = require("@aws-sdk/lib-dynamodb");
const { db } = require("../lib/aws");
const config = require("../lib/config");
const users = require("./users");
const audit = require("./audit");

class UserNotFound extends Error {}
class TargetNotActive extends Error {}
class LastOfficer extends Error {}
class NotAnOfficer extends Error {}
class Conflict extends Error {}

const ROLES = ["member", "officer"];

// Returns { userId, role, previousRole, changed }.
async function changeRole(targetId, actorId, newRole) {
  const target = await users.getUser(targetId);
  if (!target) throw new UserNotFound();
  if (target.active !== true) throw new TargetNotActive();
  if (target.role === newRole) {
    return { userId: targetId, role: newRole, previousRole: newRole, changed: false };
  }

  const oldRole = target.role;
  const self = targetId === actorId;
  const demotion = oldRole === "officer" && newRole === "member";
  const now = new Date().toISOString();

  // DynamoDB allows one operation per item in a transaction, so when officers
  // change their own role, the "still an active officer" check is part of the
  // target update's condition.
  const items = [];
  const label = [];
  items.push({
    Update: {
      TableName: config.tables.users,
      Key: { userId: targetId },
      UpdateExpression: "SET #r = :new, roleChangedAt = :now",
      ConditionExpression: "#r = :old AND active = :yes",
      ExpressionAttributeNames: { "#r": "role" },
      ExpressionAttributeValues: { ":new": newRole, ":old": oldRole, ":yes": true, ":now": now },
    },
  });
  label.push("target");
  if (!self) {
    items.push(users.activeOfficerCheck(actorId));
    label.push("actor");
  }
  items.push(demotion
    ? {
      Update: {
        TableName: config.tables.users,
        Key: { userId: users.OFFICER_COUNTER_KEY },
        UpdateExpression: "SET #c = #c - :one",
        ConditionExpression: "#c > :one",
        ExpressionAttributeNames: { "#c": "count" },
        ExpressionAttributeValues: { ":one": 1 },
      },
    }
    : {
      Update: {
        TableName: config.tables.users,
        Key: { userId: users.OFFICER_COUNTER_KEY },
        UpdateExpression: "ADD #c :one",
        ExpressionAttributeNames: { "#c": "count" },
        ExpressionAttributeValues: { ":one": 1 },
      },
    });
  label.push("counter");
  items.push(audit.entryPut({
    eventType: "role_changed",
    actorId,
    targetId,
    metadata: { oldRole, newRole },
  }));
  label.push("audit");

  try {
    await db.send(new TransactWriteCommand({ TransactItems: items }));
  } catch (err) {
    if (err.name !== "TransactionCanceledException") throw err;
    const reasons = err.CancellationReasons || [];
    const failed = (name) => reasons[label.indexOf(name)]?.Code;
    if (failed("actor") === "ConditionalCheckFailed") throw new NotAnOfficer();
    if (failed("counter") === "ConditionalCheckFailed") throw new LastOfficer();
    if (failed("target") === "ConditionalCheckFailed") {
      const now2 = await users.getUser(targetId);
      if (self && now2?.role !== "officer") throw new NotAnOfficer();
      if (now2?.role === newRole && now2.active === true) {
        return { userId: targetId, role: newRole, previousRole: newRole, changed: false };
      }
      if (now2 && now2.active !== true) throw new TargetNotActive();
      throw new Conflict();
    }
    // Another transaction touched the same items at the same moment.
    if (reasons.some((r) => r?.Code === "TransactionConflict")) throw new Conflict();
    throw err;
  }

  return { userId: targetId, role: newRole, previousRole: oldRole, changed: true };
}

module.exports = {
  changeRole, ROLES, UserNotFound, TargetNotActive, LastOfficer, NotAnOfficer, Conflict,
};
