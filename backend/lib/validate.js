// Input rules shared by the routes. The frontend checks the same rules for
// quick feedback, but only these server-side checks decide.

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// eslint-disable-next-line no-control-regex
const CONTROL_RE = /[\u0000-\u001f\u007f]/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Full date and time with a time zone, e.g. 2026-12-01T18:00:00Z.
const DATETIME_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,3})?)?(Z|[+-]\d{2}:\d{2})$/;

const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);

function fullName(v) {
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s.length >= 2 && s.length <= 100 && !CONTROL_RE.test(s) ? s : null;
}

function email(v) {
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s.length >= 3 && s.length <= 254 && EMAIL_RE.test(s) ? s : null;
}

// bcrypt only uses the first 72 bytes, so longer passwords are refused.
function newPassword(v) {
  if (typeof v !== "string") return null;
  const bytes = Buffer.byteLength(v, "utf8");
  return v.length >= 8 && bytes <= 72 ? v : null;
}

// One-line text (event titles in notices): trimmed, length in [min, max],
// no control characters.
function line(v, min, max) {
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s.length >= min && s.length <= max && !CONTROL_RE.test(s) ? s : null;
}

// ISO date-time with a time zone -> "YYYY-MM-DDTHH:mm:ss.sssZ" (UTC), or null.
function dateTime(v) {
  if (typeof v !== "string" || !DATETIME_RE.test(v)) return null;
  const t = Date.parse(v);
  return Number.isFinite(t) ? new Date(t).toISOString() : null;
}

module.exports = { isObject, fullName, email, newPassword, line, dateTime, UUID_RE, CONTROL_RE };
