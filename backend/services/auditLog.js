// Reading the audit log, newest first.
//
// FeedIndex (all entries) or TypeIndex (one event type), sorted by
// sortKey = createdAt#logId. Paging uses the logId of the last entry seen:
// the next page holds entries with a smaller sortKey, so none is skipped or
// repeated even when timestamps are equal. Actor and target names are added;
// emails and other user fields are not returned.
const { GetCommand, QueryCommand } = require("@aws-sdk/lib-dynamodb");
const { db } = require("../lib/aws");
const config = require("../lib/config");
const users = require("./users");

class UnknownCursor extends Error {}

async function listEntries({ type, limit, before }) {
  let beforeSortKey = null;
  if (before) {
    const cur = await db.send(new GetCommand({ TableName: config.tables.audit, Key: { logId: before } }));
    if (!cur.Item) throw new UnknownCursor();
    beforeSortKey = cur.Item.sortKey;
  }

  const byType = Boolean(type);
  const values = { ":p": byType ? type : "audit" };
  let condition = byType ? "eventType = :p" : "feed = :p";
  if (beforeSortKey) {
    condition += " AND sortKey < :before";
    values[":before"] = beforeSortKey;
  }
  const res = await db.send(new QueryCommand({
    TableName: config.tables.audit,
    IndexName: byType ? "TypeIndex" : "FeedIndex",
    KeyConditionExpression: condition,
    ExpressionAttributeValues: values,
    ScanIndexForward: false,
    Limit: limit,
  }));
  const items = res.Items || [];

  // Names for the people involved (one read per distinct user).
  const ids = [...new Set(items.flatMap((e) => [e.actorId, e.targetId]).filter(Boolean))];
  const names = new Map(await Promise.all(ids.map(async (id) => [id, (await users.getUser(id))?.fullName || null])));
  const person = (id) => (id ? { userId: id, fullName: names.get(id) } : null);

  return items.map((e) => ({
    logId: e.logId,
    eventType: e.eventType,
    createdAt: e.createdAt,
    actor: person(e.actorId),
    target: person(e.targetId),
    metadata: e.metadata || {},
  }));
}

module.exports = { listEntries, UnknownCursor };
