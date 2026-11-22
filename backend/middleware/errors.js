// 404 for unknown routes and one place that turns errors into JSON answers.
// Error format used by every route: { "error": "<code>", ...details }

function notFound(req, res) {
  res.status(404).json({ error: "not_found" });
}

// eslint-disable-next-line no-unused-vars
function errorHandler(err, req, res, next) {
  if (err.type === "entity.parse.failed") {
    return res.status(400).json({ error: "invalid_json" });
  }
  if (err.type === "entity.too.large") {
    return res.status(413).json({ error: "body_too_large" });
  }
  if (err.status && err.status >= 400 && err.status < 500 && err.expose) {
    return res.status(err.status).json({ error: "bad_request" });
  }
  // Log the error name only: messages can contain user input.
  console.error(`error ${err.name || "Error"} ${req.method} ${req.originalUrl.split("?")[0]}`);
  return res.status(500).json({ error: "internal_error" });
}

module.exports = { notFound, errorHandler };
