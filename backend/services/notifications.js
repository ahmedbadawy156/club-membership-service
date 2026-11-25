// Member notices (table MemberNotifications, key userId + sortKey).
//
//   store(envelope)        notifier.js: one message from the SNS topic -> one
//                          notice per member it concerns
//   listMine(userId)       GET  /api/notifications
//   markSeen(userId)       POST /api/notifications/seen
//
// A notice is unread while it is newer than the member's notificationsSeenAt
// (one field on their ClubUsers item), so "mark all as read" is one write.
// SNS can deliver a message twice: the sort key comes from the message's own
// id and time, so a second delivery finds the notice there and adds nothing.
// Notices are removed by DynamoDB TTL after 60 days.
const crypto = require("crypto");
const { PutCommand, QueryCommand, UpdateCommand } = require("@aws-sdk/lib-dynamodb");
const { db } = require("../lib/aws");
const config = require("../lib/config");
const validate = require("../lib/validate");
const users = require("./users");

const TABLE = config.notifications.table;
const KEEP_DAYS = 60;
const MAX_RECIPIENTS = 1000;

// A message that can never be stored (wrong shape or source).
class BadMessage extends Error {}

function when(iso) {
  const d = new Date(iso);
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const hh = String(d.getUTCHours()).padStart(2, "0");
  const mm = String(d.getUTCMinutes()).padStart(2, "0");
  return `${d.getUTCDate()} ${months[d.getUTCMonth()]}, ${hh}:${mm} UTC`;
}

const isId = (v) => typeof v === "string" && validate.UUID_RE.test(v);
const eventLink = (id) => `events/event.html?id=${id}`;

// Envelope -> { userIds, notice } or throws BadMessage. Only the two known
// sources, and only the kinds each one may send.
function readEnvelope(env) {
  if (!validate.isObject(env) || !validate.isObject(env.detail) || typeof env.id !== "string" || !env.id) {
    throw new BadMessage("not an envelope");
  }
  const d = env.detail;
  const kind = env["detail-type"];
  if (env.source === "club.membership") {
    if (!isId(d.userId)) throw new BadMessage("invalid userId");
    if (kind === "MembershipApproved") {
      return { userIds: [d.userId], notice: { type: kind, title: "Welcome to the club", text: "Your membership request was approved. You can now RSVP to events.", link: "events/index.html" } };
    }
    if (kind === "RoleChanged" && (d.role === "officer" || d.role === "member")) {
      return {
        userIds: [d.userId],
        notice: d.role === "officer"
          ? { type: kind, title: "You are now an officer", text: "You can review membership requests, run events and post announcements.", link: "index.html" }
          : { type: kind, title: "Your role is now member", text: "An officer changed your role to member.", link: "index.html" },
      };
    }
  } else if (env.source === "club.events") {
    if (!isId(d.eventId) || !validate.line(d.title, 1, 120) || !validate.dateTime(d.startsAt)) throw new BadMessage("invalid event");
    if (kind === "SeatPromoted" && isId(d.userId)) {
      return { userIds: [d.userId], notice: { type: kind, title: `You got a seat: ${d.title}`, text: `A seat opened up for ${d.title} on ${when(d.startsAt)}. Your RSVP is now confirmed.`, link: eventLink(d.eventId), eventId: d.eventId } };
    }
    if (kind === "EventCancelled" && Array.isArray(d.memberIds) && d.memberIds.every(isId)) {
      return { userIds: d.memberIds.slice(0, MAX_RECIPIENTS), notice: { type: kind, title: `Cancelled: ${d.title}`, text: `${d.title} on ${when(d.startsAt)} has been cancelled. Your RSVP no longer applies.`, link: eventLink(d.eventId), eventId: d.eventId } };
    }
  } else {
    throw new BadMessage("unexpected source");
  }
  throw new BadMessage(`unexpected message ${kind}`);
}

// Returns { stored, duplicates }.
async function store(env) {
  const { userIds, notice } = readEnvelope(env);
  const time = validate.dateTime(env.time) || new Date().toISOString();
  const expiresAt = Math.floor(Date.parse(time) / 1000) + KEEP_DAYS * 24 * 3600;
  let stored = 0;
  let duplicates = 0;
  for (const userId of new Set(userIds.map((u) => u.toLowerCase()))) {
    const notificationId = crypto.createHash("sha256").update(`${env.id}:${userId}`).digest("hex").slice(0, 32);
    try {
      await db.send(new PutCommand({
        TableName: TABLE,
        Item: { userId, sortKey: `${time}#${notificationId}`, notificationId, ...notice, createdAt: time, expiresAt },
        ConditionExpression: "attribute_not_exists(sortKey)",
      }));
      stored += 1;
    } catch (err) {
      if (err.name !== "ConditionalCheckFailedException") throw err;
      duplicates += 1;
    }
  }
  return { stored, duplicates };
}

function toPublic(item, seenAt) {
  return {
    id: item.notificationId,
    type: item.type,
    title: item.title,
    text: item.text,
    link: item.link || null,
    createdAt: item.createdAt,
    unread: !seenAt || item.createdAt > seenAt,
  };
}

// Newest first. unreadCount counts every unread notice, not just this page.
async function listMine(userId, limit) {
  const user = await users.getUser(userId);
  const seenAt = user?.notificationsSeenAt || "";
  const [page, unread] = await Promise.all([
    db.send(new QueryCommand({
      TableName: TABLE,
      KeyConditionExpression: "userId = :u",
      ExpressionAttributeValues: { ":u": userId },
      ScanIndexForward: false,
      Limit: limit,
    })),
    // Never marked as read: every notice is unread. (DynamoDB refuses an
    // empty string in a key condition, so that case has no sortKey part.)
    db.send(new QueryCommand(seenAt
      ? {
        TableName: TABLE,
        KeyConditionExpression: "userId = :u AND sortKey > :seen",
        ExpressionAttributeValues: { ":u": userId, ":seen": seenAt },
        Select: "COUNT",
      }
      : {
        TableName: TABLE,
        KeyConditionExpression: "userId = :u",
        ExpressionAttributeValues: { ":u": userId },
        Select: "COUNT",
      })),
  ]);
  return {
    notifications: (page.Items || []).map((i) => toPublic(i, seenAt)),
    unreadCount: unread.Count || 0,
  };
}

// Everything up to now counts as read. Returns false if the account is gone.
async function markSeen(userId) {
  try {
    await db.send(new UpdateCommand({
      TableName: config.tables.users,
      Key: { userId },
      UpdateExpression: "SET notificationsSeenAt = :now",
      ConditionExpression: "attribute_exists(userId)",
      ExpressionAttributeValues: { ":now": new Date().toISOString() },
    }));
    return true;
  } catch (err) {
    if (err.name === "ConditionalCheckFailedException") return false;
    throw err;
  }
}

module.exports = { store, listMine, markSeen, readEnvelope, BadMessage };
