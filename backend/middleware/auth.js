// Authentication and the officer check.
//
// requireUser: a valid token in "Authorization: Bearer ..." or 401.
// requireActiveOfficer: additionally the CURRENT role in ClubUsers must be
// officer and the account active, or 403. The role claim in the token is not
// trusted for officer actions, because it can be up to 15 minutes old.
const { verifyToken } = require("../lib/tokens");
const users = require("../services/users");

async function requireUser(req, res, next) {
  try {
    const header = req.headers.authorization || "";
    const match = header.match(/^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/);
    if (!match) return res.status(401).json({ error: "sign_in_required" });
    const claims = await verifyToken(match[1]);
    if (!claims || typeof claims.sub !== "string") {
      return res.status(401).json({ error: "invalid_token" });
    }
    req.user = { id: claims.sub, role: claims.role, name: claims.name };
    return next();
  } catch (err) {
    return next(err);
  }
}

async function requireActiveOfficer(req, res, next) {
  try {
    const current = await users.getUser(req.user.id);
    if (!current || current.role !== "officer" || current.active !== true) {
      return res.status(403).json({ error: "officer_only" });
    }
    req.officer = current;
    return next();
  } catch (err) {
    return next(err);
  }
}

module.exports = { requireUser, requireActiveOfficer };
