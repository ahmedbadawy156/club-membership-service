// POST /api/membership-requests: a visitor asks to join the club.
const validate = require("../lib/validate");
const { hashPassword } = require("../lib/passwords");
const { clientIpHash } = require("../lib/clientIp");
const config = require("../lib/config");
const rateLimits = require("../services/rateLimits");
const requests = require("../services/membershipRequests");

async function submit(req, res, next) {
  try {
    // A signed-in member already has an account.
    if (req.headers.authorization) {
      return res.status(403).json({ error: "already_signed_in" });
    }

    const body = validate.isObject(req.body) ? req.body : {};
    const fullName = validate.fullName(body.fullName);
    const email = validate.email(body.email);
    const password = validate.newPassword(body.password);
    const fields = [];
    if (!fullName) fields.push("fullName");
    if (!email) fields.push("email");
    if (!password) fields.push("password");
    if (fields.length > 0) {
      return res.status(400).json({ error: "validation_failed", fields });
    }

    // Limits before anything is stored.
    const sourceIpHash = await clientIpHash(req);
    const slot = await rateLimits.takeSlot("request", sourceIpHash,
      config.limits.requestsPerHourPerAddress, 3600);
    if (!slot.allowed) {
      res.set("Retry-After", String(slot.retryAfter));
      return res.status(429).json({ error: "rate_limited" });
    }
    if (await requests.countPending() >= config.limits.maxPendingRequests) {
      res.set("Retry-After", "3600");
      return res.status(429).json({ error: "too_many_pending_requests" });
    }

    const passwordHash = await hashPassword(password);
    const created = await requests.createRequest({ fullName, email, passwordHash, sourceIpHash });
    return res.status(201).json(created);
  } catch (err) {
    if (err instanceof requests.EmailTaken) {
      return res.status(409).json({ error: "email_already_registered" });
    }
    return next(err);
  }
}

module.exports = { submit };
