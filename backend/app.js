// The Express app: middleware and routes. It does not start a server.
//   server.js -> runs it on your PC (npm run dev)
//   lambda.js -> runs it on AWS Lambda (Floci)
require("dotenv").config({ quiet: true });

const express = require("express");
const cors = require("cors");
const requestLog = require("./middleware/requestLog");
const { notFound, errorHandler } = require("./middleware/errors");
const healthRoutes = require("./routes/health");

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
  maxAge: 600,
}));

// JSON bodies up to 4 KB; larger bodies get 413 from the error handler.
app.use(express.json({ limit: "4kb" }));

app.use("/api/health", healthRoutes);

app.use(notFound);
app.use(errorHandler);

module.exports = app;
