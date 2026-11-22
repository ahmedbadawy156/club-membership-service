// One line per request: time, method, path (no query string), status and
// duration. The body, query string and headers are never logged, so
// passwords, tokens, emails and search text never reach the logs.
module.exports = function requestLog(req, res, next) {
  const started = Date.now();
  res.on("finish", () => {
    const path = req.originalUrl.split("?")[0];
    console.log(`${new Date().toISOString()} ${req.method} ${path} ${res.statusCode} ${Date.now() - started}ms`);
  });
  next();
};
