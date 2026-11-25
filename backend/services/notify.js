// Sends member notices to the SNS topic "club-member-notifications".
//
// Two kinds of publisher use the topic, with the same message shape (an
// EventBridge-style envelope), so the notifier reads one format:
//   - this service:   MembershipApproved, RoleChanged       (source club.membership)
//   - the club bus:   EventCancelled, SeatPromoted          (source club.events,
//                     forwarded by the rule club-events-to-notifications)
// The topic pushes every message to the notifier Lambda (notifier.js), which
// stores one notice per member in MemberNotifications.
//
// Best effort: the approval or role change is already saved, so an SNS
// failure is retried once and logged, never turned into an error.
const crypto = require("crypto");
const { SNSClient, PublishCommand } = require("@aws-sdk/client-sns");
const config = require("../lib/config");

const sns = new SNSClient({});

async function publish(detailType, detail) {
  if (!config.notifications.topicArn) return false; // not configured (npm run dev)
  const Message = JSON.stringify({
    id: crypto.randomUUID(),
    source: "club.membership",
    "detail-type": detailType,
    time: new Date().toISOString(),
    detail,
  });
  let error;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      await sns.send(new PublishCommand({ TopicArn: config.notifications.topicArn, Message }));
      return true;
    } catch (err) {
      error = err.name;
    }
  }
  console.error(JSON.stringify({ level: "error", msg: "notification_publish_failed", detailType, error }));
  return false;
}

const membershipApproved = (userId) => publish("MembershipApproved", { userId });
const roleChanged = (userId, role) => publish("RoleChanged", { userId, role });

module.exports = { membershipApproved, roleChanged };
