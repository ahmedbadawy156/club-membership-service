// Lambda "club-membership-notifier": subscribed to the SNS topic
// "club-member-notifications". SNS pushes each message here; it is stored as
// one notice per member it concerns (services/notifications.js).
//
// A message that cannot be stored throws, so Lambda retries the delivery
// (SNS invokes asynchronously: two more tries). A message with the wrong
// shape is logged and dropped: retrying it would never help.
const notifications = require("./services/notifications");

exports.handler = async (event) => {
  for (const record of event.Records || []) {
    const messageId = record.Sns?.MessageId;
    let envelope;
    try {
      envelope = JSON.parse(record.Sns?.Message || "");
    } catch {
      envelope = null;
    }
    try {
      const result = await notifications.store(envelope);
      console.log(JSON.stringify({ level: "info", msg: "notice_stored", messageId, kind: envelope["detail-type"], ...result }));
    } catch (err) {
      if (err instanceof notifications.BadMessage) {
        // Never log the message itself: only its id and what was wrong.
        console.error(JSON.stringify({ level: "error", msg: "notice_dropped", messageId, error: err.message }));
        continue;
      }
      throw err;
    }
  }
};
