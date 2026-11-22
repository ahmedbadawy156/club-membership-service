// Member routes (officers only).
//   GET   /api/members?search=&status=&limit=&offset=
//   PATCH /api/members/:id/role   { "role": "member" | "officer" }
const validate = require("../lib/validate");
const roles = require("../services/roles");
const memberSearch = require("../services/memberSearch");

const STATUSES = ["active", "inactive", "all"];

// Whole-number query parameter within [min, max]; null if invalid.
function intParam(value, fallback, min, max) {
  if (value === undefined) return fallback;
  if (typeof value !== "string" || !/^\d{1,6}$/.test(value)) return null;
  const n = Number(value);
  return n >= min && n <= max ? n : null;
}

async function list(req, res, next) {
  try {
    const q = req.query;
    const fields = [];
    const search = typeof q.search === "string" ? q.search.trim() : q.search === undefined ? "" : null;
    if (search === null || search.length > 100 || validate.CONTROL_RE.test(search)) fields.push("search");
    const status = q.status ?? "active";
    if (!STATUSES.includes(status)) fields.push("status");
    const limit = intParam(q.limit, 50, 1, 100);
    if (limit === null) fields.push("limit");
    const offset = intParam(q.offset, 0, 0, 100000);
    if (offset === null) fields.push("offset");
    if (fields.length > 0) return res.status(400).json({ error: "validation_failed", fields });

    return res.status(200).json(await memberSearch.searchMembers({ search, status, limit, offset }));
  } catch (err) {
    return next(err);
  }
}

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

module.exports = { list, changeRole, intParam };
