// Member routes (officers only).
//   PATCH /api/members/:id/role   { "role": "member" | "officer" }
const validate = require("../lib/validate");
const roles = require("../services/roles");

async function changeRole(req, res, next) {
  try {
    const { id } = req.params;
    if (!validate.UUID_RE.test(id)) {
      return res.status(400).json({ error: "validation_failed", fields: ["id"] });
    }
    const role = validate.isObject(req.body) ? req.body.role : undefined;
    if (!roles.ROLES.includes(role)) {
      return res.status(400).json({ error: "validation_failed", fields: ["role"] });
    }
    return res.status(200).json(await roles.changeRole(id, req.officer.userId, role));
  } catch (err) {
    if (err instanceof roles.UserNotFound) return res.status(404).json({ error: "user_not_found" });
    if (err instanceof roles.TargetNotActive) return res.status(409).json({ error: "target_not_active" });
    if (err instanceof roles.LastOfficer) return res.status(409).json({ error: "last_officer" });
    if (err instanceof roles.NotAnOfficer) return res.status(403).json({ error: "officer_only" });
    if (err instanceof roles.Conflict) return res.status(409).json({ error: "conflict" });
    return next(err);
  }
}

module.exports = { changeRole };
