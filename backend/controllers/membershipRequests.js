// Membership request routes.
//   POST  /api/membership-requests         visitor asks to join (public)
//   GET   /api/membership-requests?status= officer lists requests
//   PATCH /api/membership-requests/:id     officer approves or rejects once
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

async function list(req, res, next) {
  try {
    const status = req.query.status ?? "pending";
    if (typeof status !== "string" || !requests.STATUSES.includes(status)) {
      return res.status(400).json({ error: "validation_failed", fields: ["status"] });
    }
    return res.status(200).json({ requests: await requests.listByStatus(status) });
  } catch (err) {
    return next(err);
  }
}

async function review(req, res, next) {
  try {
    const { id } = req.params;
    if (!validate.UUID_RE.test(id)) {
      return res.status(400).json({ error: "validation_failed", fields: ["id"] });
    }
    const decision = validate.isObject(req.body) ? req.body.decision : undefined;
    if (decision !== "approve" && decision !== "reject") {
      return res.status(400).json({ error: "validation_failed", fields: ["decision"] });
    }
    const result = await requests.review(id, req.officer.userId, decision);
    const { userId, ...publicResult } = result;
    return res.status(200).json(publicResult);
  } catch (err) {
    if (err instanceof requests.NotFound) return res.status(404).json({ error: "request_not_found" });
    if (err instanceof requests.AlreadyDecided) return res.status(409).json({ error: "already_decided" });
    if (err instanceof requests.NotAnOfficer) return res.status(403).json({ error: "officer_only" });
    return next(err);
  }
}

module.exports = { submit, list, review };
