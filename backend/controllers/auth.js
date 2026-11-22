// Auth routes.
//   POST /api/auth/login       sign in, receive a 15-minute token
//   GET  /api/auth/public-key  the key Events and Announcements verify with
const validate = require("../lib/validate");
const { clientIpHash } = require("../lib/clientIp");
const tokens = require("../lib/tokens");
const rateLimits = require("../services/rateLimits");
const login = require("../services/login");

const LOGINS_PER_ADDRESS = 20;
const LOGIN_WINDOW_SECONDS = 15 * 60;

async function signIn(req, res, next) {
  try {
    if (req.headers.authorization) {
      return res.status(403).json({ error: "already_signed_in" });
    }

    const body = validate.isObject(req.body) ? req.body : {};
    const email = validate.email(body.email);
    const password = typeof body.password === "string" ? body.password : "";
    const pwBytes = Buffer.byteLength(password, "utf8");
    const fields = [];
    if (!email) fields.push("email");
    if (pwBytes < 1 || pwBytes > 72) fields.push("password");
    if (fields.length > 0) {
      return res.status(400).json({ error: "validation_failed", fields });
    }

    const slot = await rateLimits.takeSlot("login", await clientIpHash(req),
      LOGINS_PER_ADDRESS, LOGIN_WINDOW_SECONDS);
    if (!slot.allowed) {
      res.set("Retry-After", String(slot.retryAfter));
      return res.status(429).json({ error: "rate_limited" });
    }

    const result = await login.attemptLogin(email, password);
    if (!result.ok && result.reason === "locked") {
      res.set("Retry-After", String(Math.max(1, result.retryAfter)));
      return res.status(423).json({ error: "account_locked" });
    }
    // Wrong password, unknown email and inactive account all look the same.
    if (!result.ok) {
      return res.status(401).json({ error: "invalid_credentials" });
    }

    const { user } = result;
    const signed = await tokens.signToken(user);
    return res.status(200).json({
      accessToken: signed.token,
      tokenType: "Bearer",
      expiresIn: signed.expiresIn,
      expiresAt: signed.expiresAt,
      user: { id: user.userId, fullName: user.fullName, role: user.role },
    });
  } catch (err) {
    return next(err);
  }
}

async function publicKey(req, res, next) {
  try {
    res.set("Cache-Control", "public, max-age=300");
    return res.status(200).json({
      algorithm: "RS256",
      issuer: tokens.ISSUER,
      audience: tokens.AUDIENCE,
      publicKey: await tokens.publicKey(),
    });
  } catch (err) {
    return next(err);
  }
}

module.exports = { signIn, publicKey };
