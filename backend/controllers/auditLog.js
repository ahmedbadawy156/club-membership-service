// GET /api/audit-log?type=&limit=&before=<logId>   (officers only)
const validate = require("../lib/validate");
const { intParam } = require("./members");
const audit = require("../services/audit");
const auditLog = require("../services/auditLog");

async function list(req, res, next) {
  try {
    const q = req.query;
    const fields = [];
    const type = q.type;
    if (type !== undefined && !audit.EVENT_TYPES.includes(type)) fields.push("type");
    const limit = intParam(q.limit, 50, 1, 100);
    if (limit === null) fields.push("limit");
    const before = q.before;
    if (before !== undefined && (typeof before !== "string" || !validate.UUID_RE.test(before))) fields.push("before");
    if (fields.length > 0) return res.status(400).json({ error: "validation_failed", fields });

    return res.status(200).json({ entries: await auditLog.listEntries({ type, limit, before }) });
  } catch (err) {
    if (err instanceof auditLog.UnknownCursor) {
      return res.status(400).json({ error: "validation_failed", fields: ["before"] });
    }
    return next(err);
  }
}

module.exports = { list };
