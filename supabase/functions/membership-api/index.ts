import { withSupabase } from "@supabase/server";
import type { SupabaseContext } from "@supabase/server";

type Ctx = SupabaseContext;

const MAX_BODY_BYTES = 4096;
// Long enough to mean "until an officer approves the request".
const PENDING_BAN_DURATION = "876000h";

const json = (body: unknown, status = 200, headers: HeadersInit = {}) =>
  Response.json(body, { status, headers });

const errorResponse = (
  status: number,
  error: string,
  extra: Record<string, unknown> = {},
  headers: HeadersInit = {},
) => json({ error, ...extra }, status, headers);

// Path inside the function, e.g. "/health" or "/membership-requests".
function routePath(req: Request): string {
  const path = new URL(req.url).pathname;
  const inner = path.replace(/^.*?\/membership-api/, "");
  return inner === "" ? "/" : inner.replace(/\/+$/, "") || "/";
}

// ---------- helpers ----------

class BodyTooLarge extends Error {}

async function readJsonBody(req: Request): Promise<unknown> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) throw new BodyTooLarge();

  if (!req.body) return null;
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel();
      throw new BodyTooLarge();
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    bytes.set(c, offset);
    offset += c.byteLength;
  }
  const text = new TextDecoder().decode(bytes);
  if (text.trim() === "") return null;
  return JSON.parse(text);
}

// The proxy in front of the function appends the address it saw to the
// end of X-Forwarded-For, so the last entry is the one a client cannot
// forge. Hosted Supabase behaviour must be re-checked before deployment.
function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) {
    const parts = xff.split(",").map((p) => p.trim()).filter(Boolean);
    if (parts.length > 0) return parts[parts.length - 1];
  }
  return req.headers.get("x-real-ip")?.trim() || "unknown";
}

async function hashIp(ip: string, salt: string): Promise<string> {
  const data = new TextEncoder().encode(`${salt}:${ip}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// deno-lint-ignore no-control-regex
const CONTROL_RE = /[\u0000-\u001f\u007f]/;

type Submission = { fullName: string; email: string; password: string };

function validateSubmission(
  body: unknown,
): { ok: true; value: Submission } | { ok: false; fields: string[] } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, fields: ["body"] };
  }
  const b = body as Record<string, unknown>;
  const fields: string[] = [];

  const fullName = typeof b.fullName === "string" ? b.fullName.trim() : "";
  if (
    fullName.length < 2 || fullName.length > 100 || CONTROL_RE.test(fullName)
  ) {
    fields.push("fullName");
  }

  const email = typeof b.email === "string"
    ? b.email.trim().toLowerCase()
    : "";
  if (email.length < 3 || email.length > 254 || !EMAIL_RE.test(email)) {
    fields.push("email");
  }

  // Supabase Auth hashes with bcrypt, which only uses the first 72 bytes.
  const password = typeof b.password === "string" ? b.password : "";
  const pwBytes = new TextEncoder().encode(password).byteLength;
  if (password.length < 8 || pwBytes > 72) fields.push("password");

  if (fields.length > 0) return { ok: false, fields };
  return { ok: true, value: { fullName, email, password } };
}

// ---------- routes ----------

function health(): Response {
  return json({ service: "membership", status: "ok" });
}

async function submitMembershipRequest(
  req: Request,
  ctx: Ctx,
): Promise<Response> {
  // Public route: the publishable key only. A signed-in user already has
  // an account and must not create another.
  if (ctx.authMode !== "publishable") {
    return errorResponse(403, "already_signed_in");
  }

  const salt = Deno.env.get("MEMBERSHIP_IP_HASH_SALT");
  if (!salt) {
    console.error("membership-requests: MEMBERSHIP_IP_HASH_SALT is not set");
    return errorResponse(500, "server_misconfigured");
  }

  let body: unknown;
  try {
    body = await readJsonBody(req);
  } catch (err) {
    if (err instanceof BodyTooLarge) {
      return errorResponse(413, "body_too_large");
    }
    return errorResponse(400, "invalid_json");
  }

  const result = validateSubmission(body);
  if (!result.ok) {
    return errorResponse(400, "validation_failed", { fields: result.fields });
  }
  const { fullName, email, password } = result.value;

  const admin = ctx.supabaseAdmin;

  // Rate limit before anything is created.
  const ipHash = await hashIp(clientIp(req), salt);
  const { data: limit, error: limitError } = await admin.rpc(
    "record_membership_request_attempt",
    { p_ip_hash: ipHash },
  );
  if (limitError) {
    console.error("membership-requests: rate limit check failed", {
      code: limitError.code,
    });
    return errorResponse(500, "internal_error");
  }
  if (limit !== "ok") {
    return errorResponse(429, "rate_limited", {}, { "Retry-After": "3600" });
  }

  // Create the Auth account, banned until an officer approves it.
  const { data: created, error: createError } = await admin.auth.admin
    .createUser({
      email,
      password,
      email_confirm: true,
      ban_duration: PENDING_BAN_DURATION,
    });
  if (createError || !created?.user) {
    const code = (createError as { code?: string } | null)?.code;
    if (code === "email_exists" || code === "user_already_exists") {
      return errorResponse(409, "email_already_registered");
    }
    if (code === "weak_password" || code === "validation_failed") {
      return errorResponse(400, "validation_failed", { fields: ["password"] });
    }
    console.error("membership-requests: createUser failed", { code });
    return errorResponse(500, "internal_error");
  }
  const userId = created.user.id;

  // Profile and request in one transaction.
  const { data: requestId, error: submitError } = await admin.rpc(
    "submit_membership_request",
    { p_user_id: userId, p_full_name: fullName, p_email: email },
  );
  if (submitError || !requestId) {
    // Undo the Auth account so no orphan is left behind.
    const { error: deleteError } = await admin.auth.admin.deleteUser(userId);
    if (deleteError) {
      console.error("membership-requests: cleanup deleteUser failed", {
        userId,
      });
    }
    if (submitError?.code === "23505") {
      return errorResponse(409, "email_already_registered");
    }
    if (submitError?.code === "23514") {
      return errorResponse(400, "validation_failed");
    }
    console.error("membership-requests: submit failed", {
      code: submitError?.code,
    });
    return errorResponse(500, "internal_error");
  }

  return json({ requestId, status: "pending" }, 201);
}

// ---------- router ----------

export default {
  fetch: withSupabase(
    { auth: ["user", "publishable"] },
    async (req, ctx) => {
      const path = routePath(req);

      if (path === "/health") {
        if (req.method !== "GET") {
          return errorResponse(405, "method_not_allowed", {}, { Allow: "GET" });
        }
        return health();
      }

      if (path === "/membership-requests") {
        if (req.method !== "POST") {
          return errorResponse(405, "method_not_allowed", {}, {
            Allow: "POST",
          });
        }
        return await submitMembershipRequest(req, ctx);
      }

      return errorResponse(404, "not_found");
    },
  ),
};
