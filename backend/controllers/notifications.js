// Notification routes (signed-in members and officers; always your own).
//   GET  /api/notifications?limit=1..50   newest first, with unreadCount
//   POST /api/notifications/seen          mark everything up to now as read
// The member is always the token's user: no id is read from the request.
const notifications = require("../services/notifications");
const { intParam } = require("./members");

async function listMine(req, res, next) {
  try {
    const limit = intParam(req.query.limit, 20, 1, 50);
    if (limit === null) return res.status(400).json({ error: "validation_failed", fields: ["limit"] });
    return res.status(200).json(await notifications.listMine(req.user.id, limit));
  } catch (err) {
    return next(err);
  }
}

async function markSeen(req, res, next) {
  try {
    if (!(await notifications.markSeen(req.user.id))) return res.status(404).json({ error: "user_not_found" });
    return res.status(204).end();
  } catch (err) {
    return next(err);
  }
}

module.exports = { listMine, markSeen };
