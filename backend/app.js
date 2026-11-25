// The Express app: middleware and routes. It does not start a server.
//   server.js -> runs it on your PC (npm run dev)
//   lambda.js -> runs it on AWS Lambda (Floci)
require("dotenv").config({ quiet: true });

const express = require("express");
const cors = require("cors");
const requestLog = require("./middleware/requestLog");
const { notFound, errorHandler } = require("./middleware/errors");
const healthRoutes = require("./routes/health");
const membershipRequestRoutes = require("./routes/membershipRequests");
const authRoutes = require("./routes/auth");
const memberRoutes = require("./routes/members");
const auditLogRoutes = require("./routes/auditLog");
const notificationRoutes = require("./routes/notifications");

const app = express();
app.disable("x-powered-by");

// One log line per request (CloudWatch Logs on Lambda). Never the body.
app.use(requestLog);

// CORS: only the exact origins listed in CORS_ORIGINS (comma-separated).
// Other origins get no Access-Control-Allow-Origin header, so the browser
// will not let their pages read our answers. CORS protects browsers only;
// the API itself is protected by tokens and role checks.
const allowedOrigins = (process.env.CORS_ORIGINS || "")
  .split(",")
  .map((origin) => origin.trim())
  .filter(Boolean);

app.use(cors({
  origin: (origin, callback) => callback(null, Boolean(origin) && allowedOrigins.includes(origin)),
  methods: ["GET", "POST", "PATCH", "OPTIONS"],
  allowedHeaders: ["authorization", "content-type"],
  exposedHeaders: ["Retry-After"], // lets the page show how long a lock or limit lasts
  maxAge: 600,
}));

const BODY_LIMIT_BYTES = 4096;

// On Lambda, serverless-http hands Express the body as raw bytes in req.body,
// and Express 5's JSON parser skips any request whose body is already set.
// So the raw bytes are parsed here, with the same limit and error codes.
app.use((req, res, next) => {
  if (!Buffer.isBuffer(req.body)) return next();
  const raw = req.body;
  req.body = undefined;
  if (raw.length === 0) return next();
  if (raw.length > BODY_LIMIT_BYTES) return res.status(413).json({ error: "body_too_large" });
  if (!req.is("application/json")) return next();
  try {
    req.body = JSON.parse(raw.toString("utf8"));
  } catch {
    return res.status(400).json({ error: "invalid_json" });
  }
  req._body = true; // tell express.json the body is already parsed
  return next();
});

// On your PC: JSON bodies up to 4 KB; larger bodies get 413.
app.use(express.json({ limit: BODY_LIMIT_BYTES }));

app.use("/api/health", healthRoutes);
app.use("/api/membership-requests", membershipRequestRoutes);
app.use("/api/auth", authRoutes);
app.use("/api/members", memberRoutes);
app.use("/api/audit-log", auditLogRoutes);
app.use("/api/notifications", notificationRoutes);

app.use(notFound);
app.use(errorHandler);

module.exports = app;
