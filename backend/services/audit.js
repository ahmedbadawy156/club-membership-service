// Audit log entries. Entries are only ever added (the IAM role cannot update
// or delete them). Metadata never holds emails, passwords, tokens or IPs.
const crypto = require("crypto");
const config = require("../lib/config");

const EVENT_TYPES = [
  "login_failure",
  "account_locked",
  "membership_approved",
  "membership_rejected",
  "role_changed",
];

// A Put item for a transaction. sortKey = createdAt#logId gives newest-first
// paging that never skips entries with the same timestamp.
function entryPut({ eventType, actorId = null, targetId = null, metadata = {} }) {
  if (!EVENT_TYPES.includes(eventType)) throw new Error("unknown audit event type");
  const logId = crypto.randomUUID();
  const createdAt = new Date().toISOString();
  return {
    Put: {
      TableName: config.tables.audit,
      Item: {
        logId,
        feed: "audit",
        eventType,
        sortKey: `${createdAt}#${logId}`,
        createdAt,
        actorId,
        targetId,
        metadata,
      },
      ConditionExpression: "attribute_not_exists(logId)",
    },
  };
}

module.exports = { entryPut, EVENT_TYPES };
