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

// ---------- officer check ----------
//
// Membership owns the profiles table, so it checks the current role and
// active flag there on every request instead of trusting the token's
// role claim, which can be up to jwt_expiry old.

type OfficerCheck =
  | { ok: true; officerId: string }
  | { ok: false; response: Response };

async function requireActiveOfficer(ctx: Ctx): Promise<OfficerCheck> {
  const claims = ctx.userClaims;
  if (
    ctx.authMode !== "user" || !claims?.id || claims.role !== "authenticated"
  ) {
    return { ok: false, response: errorResponse(401, "sign_in_required") };
  }

  const { data, error } = await ctx.supabaseAdmin
    .from("profiles")
    .select("role, active")
    .eq("user_id", claims.id)
    .maybeSingle();
  if (error) {
    console.error("officer check failed", { code: error.code });
    return { ok: false, response: errorResponse(500, "internal_error") };
  }
  if (!data || data.role !== "officer" || data.active !== true) {
    return { ok: false, response: errorResponse(403, "officer_only") };
  }
  return { ok: true, officerId: claims.id };
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const REQUEST_STATUSES = ["pending", "approved", "rejected"];
const MAX_LIST = 100;

// ---------- routes ----------

function health(): Response {
  return json({ service: "membership", status: "ok" });
}

async function listMembershipRequests(
  req: Request,
  ctx: Ctx,
): Promise<Response> {
  const officer = await requireActiveOfficer(ctx);
  if (!officer.ok) return officer.response;

  const status = new URL(req.url).searchParams.get("status") ?? "pending";
  if (!REQUEST_STATUSES.includes(status)) {
    return errorResponse(400, "validation_failed", { fields: ["status"] });
  }

  const { data, error } = await ctx.supabaseAdmin
    .from("membership_requests")
    .select(
      "request_id, full_name, email, status, submitted_at, reviewed_at, reviewed_by",
    )
    .eq("status", status)
    .order("submitted_at", { ascending: true })
    .limit(MAX_LIST);
  if (error) {
    console.error("list membership requests failed", { code: error.code });
    return errorResponse(500, "internal_error");
  }

  return json({
    requests: (data ?? []).map((r) => ({
      requestId: r.request_id,
      fullName: r.full_name,
      email: r.email,
      status: r.status,
      submittedAt: r.submitted_at,
      reviewedAt: r.reviewed_at,
      reviewedBy: r.reviewed_by,
    })),
  });
}

async function reviewMembershipRequest(
  req: Request,
  ctx: Ctx,
  requestId: string,
): Promise<Response> {
  const officer = await requireActiveOfficer(ctx);
  if (!officer.ok) return officer.response;

  if (!UUID_RE.test(requestId)) {
    return errorResponse(400, "validation_failed", { fields: ["id"] });
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
  const decision = (body as { decision?: unknown } | null)?.decision;
  if (decision !== "approve" && decision !== "reject") {
    return errorResponse(400, "validation_failed", { fields: ["decision"] });
  }

  const admin = ctx.supabaseAdmin;

  // Database step: decision, profile activation and audit log together.
  const { data: result, error: reviewError } = await admin.rpc(
    "review_membership_request",
    {
      p_request_id: requestId,
      p_reviewer_id: officer.officerId,
      p_decision: decision,
    },
  );
  if (reviewError) {
    switch (reviewError.code) {
      case "MB403":
        return errorResponse(403, "officer_only");
      case "MB404":
        return errorResponse(404, "request_not_found");
      case "MB409":
        return errorResponse(409, "already_decided");
      case "22023":
      case "22P02":
        return errorResponse(400, "validation_failed");
      default:
        console.error("review membership request failed", {
          code: reviewError.code,
        });
        return errorResponse(500, "internal_error");
    }
  }

  const { userId, status, alreadyDecided } = result as {
    userId: string;
    status: string;
    alreadyDecided: boolean;
  };

  // Auth step on approval: lift the ban and give the member role claim.
  // Safe to repeat, so a failure here can be fixed by sending the same
  // decision again.
  if (status === "approved") {
    const { error: authError } = await admin.auth.admin.updateUserById(
      userId,
      { ban_duration: "none", app_metadata: { role: "member" } },
    );
    if (authError) {
      console.error("approval auth update failed", {
        requestId,
        code: (authError as { code?: string }).code,
      });
      return errorResponse(500, "auth_update_failed", {
        status,
        retry: "send the same decision again",
      });
    }
  }

  return json({ requestId, status, alreadyDecided });
}

async function changeMemberRole(
  req: Request,
  ctx: Ctx,
  targetId: string,
): Promise<Response> {
  const officer = await requireActiveOfficer(ctx);
  if (!officer.ok) return officer.response;

  if (!UUID_RE.test(targetId)) {
    return errorResponse(400, "validation_failed", { fields: ["id"] });
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
  const role = (body as { role?: unknown } | null)?.role;
  if (role !== "member" && role !== "officer") {
    return errorResponse(400, "validation_failed", { fields: ["role"] });
  }

  const admin = ctx.supabaseAdmin;

  // Database step: roster lock, last-officer rule, role and audit log.
  const { data: result, error: changeError } = await admin.rpc(
    "change_member_role",
    { p_target_id: targetId, p_actor_id: officer.officerId, p_new_role: role },
  );
  if (changeError) {
    switch (changeError.code) {
      case "MB403":
        return errorResponse(403, "officer_only");
      case "MB404":
        return errorResponse(404, "user_not_found");
      case "MB409":
        return errorResponse(409, "target_not_active");
      case "MB410":
        return errorResponse(409, "last_officer");
      case "22023":
      case "22P02":
        return errorResponse(400, "validation_failed");
      default:
        console.error("change member role failed", { code: changeError.code });
        return errorResponse(500, "internal_error");
    }
  }

  const { userId, role: newRole, previousRole, changed } = result as {
    userId: string;
    role: string;
    previousRole: string;
    changed: boolean;
  };

  // Auth step: the role claim that Events and Announcements read. Runs on
  // repeats too, so sending the same request again fixes a failed update.
  const { error: authError } = await admin.auth.admin.updateUserById(userId, {
    app_metadata: { role: newRole },
  });
  if (authError) {
    console.error("role change auth update failed", {
      userId,
      code: (authError as { code?: string }).code,
    });
    return errorResponse(500, "auth_update_failed", {
      role: newRole,
      retry: "send the same request again",
    });
  }

  return json({ userId, role: newRole, previousRole, changed });
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

// ---------- CORS ----------
//
// Only origins listed in FRONTEND_ORIGINS (comma-separated, exact match)
// get CORS headers. Any other origin gets none, so the browser will not
// let that page read the response. If the variable is missing, no origin
// is allowed.

const CORS_ALLOW_HEADERS = "authorization, apikey, content-type, x-client-info";
const CORS_ALLOW_METHODS = "GET, POST, PATCH, OPTIONS";

function allowedOrigins(): string[] {
  return (Deno.env.get("FRONTEND_ORIGINS") ?? "")
    .split(",")
    .map((o) => o.trim())
    .filter(Boolean);
}

function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("origin");
  if (!origin || !allowedOrigins().includes(origin)) return {};
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": CORS_ALLOW_HEADERS,
    "Access-Control-Allow-Methods": CORS_ALLOW_METHODS,
    "Access-Control-Max-Age": "600",
  };
}

function withCors(res: Response, req: Request): Response {
  const out = new Response(res.body, res);
  for (const [k, v] of Object.entries(corsHeaders(req))) out.headers.set(k, v);
  // Responses differ by Origin, so caches must not mix them.
  out.headers.append("Vary", "Origin");
  return out;
}

// ---------- router ----------

const api = withSupabase(
  // CORS is handled below with the allow-list instead of the default "*".
  { auth: ["user", "publishable"], cors: "disabled" },
  async (req, ctx) => {
    const path = routePath(req);

    if (path === "/health") {
      if (req.method !== "GET") {
        return errorResponse(405, "method_not_allowed", {}, { Allow: "GET" });
      }
      return health();
    }

    if (path === "/membership-requests") {
      if (req.method === "POST") return await submitMembershipRequest(req, ctx);
      if (req.method === "GET") return await listMembershipRequests(req, ctx);
      return errorResponse(405, "method_not_allowed", {}, {
        Allow: "GET, POST",
      });
    }

    const item = path.match(/^\/membership-requests\/([^/]+)$/);
    if (item) {
      if (req.method !== "PATCH") {
        return errorResponse(405, "method_not_allowed", {}, {
          Allow: "PATCH",
        });
      }
      return await reviewMembershipRequest(req, ctx, item[1]);
    }

    const roleItem = path.match(/^\/members\/([^/]+)\/role$/);
    if (roleItem) {
      if (req.method !== "PATCH") {
        return errorResponse(405, "method_not_allowed", {}, {
          Allow: "PATCH",
        });
      }
      return await changeMemberRole(req, ctx, roleItem[1]);
    }

    return errorResponse(404, "not_found");
  },
);

export default {
  async fetch(req: Request): Promise<Response> {
    // Browser preflight: answered here, before any credential check,
    // because preflight requests never carry credentials.
    if (req.method === "OPTIONS") {
      const headers = corsHeaders(req);
      const allowed = "Access-Control-Allow-Origin" in headers;
      return withCors(new Response(null, { status: allowed ? 204 : 403 }), req);
    }
    return withCors(await api(req), req);
  },
};
