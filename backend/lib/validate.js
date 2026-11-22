// Input rules shared by the routes. The frontend checks the same rules for
// quick feedback, but only these server-side checks decide.

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// eslint-disable-next-line no-control-regex
const CONTROL_RE = /[\u0000-\u001f\u007f]/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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

module.exports = { isObject, fullName, email, newPassword, UUID_RE, CONTROL_RE };
