# club-membership-service

Membership and Roles service for Team 10's Campus Club Management project
(Cloud Computing and Cloud Security, 26CSCN29H).

Owner: Ahmed Emad Badawy

This repository holds only the Membership service: one Supabase Edge
Function (`membership-api`), its database migrations, scripts and tests.
The other services and the frontend live in their own repositories:
`club-events-service`, `club-announcements-service` and `club-frontend`.

> **Status:** built and tested on a local Supabase stack only. Nothing is
> deployed. Supabase as the cloud provider is a proposal that still needs
> TA approval, so no hosted project has been created.

## What the service does

- Prospective members submit a membership request with a chosen password.
  Their account is created but banned until an officer approves it.
- Officers list requests and approve or reject each one once. Approval
  activates the account and gives it the `member` role.
- Officers change roles between `member` and `officer`. The last active
  officer cannot be demoted.
- Members sign in through the login endpoint, which locks an account for
  15 minutes after 5 failed attempts.
- Officers search members and read an append-only audit log of approvals,
  rejections, role changes, login failures and lockouts.

Roles are stored in `profiles` (checked by this service on every request)
and copied into the token's `app_metadata.role`, which the Events and
Announcements services read.

## Endpoints

Base path: `/functions/v1/membership-api` on the Supabase project. Every
request needs the `apikey` header with the publishable key; officer
routes also need `Authorization: Bearer <access token>`.

| Method | Path | Who | Success | Errors |
|---|---|---|---|---|
| GET | `/health` | Public (publishable key) | 200 | 401 |
| POST | `/auth/login` | Public | 200 | 400, 401, 403, 413, 423, 429, 503 |
| POST | `/membership-requests` | Public | 201 | 400, 401, 403, 409, 413, 429 |
| GET | `/membership-requests?status=pending\|approved\|rejected` | Officer | 200 | 400, 401, 403 |
| PATCH | `/membership-requests/:id` with `{"decision":"approve"\|"reject"}` | Officer | 200 | 400, 401, 403, 404, 409 |
| GET | `/members?search=&status=active\|inactive\|all&limit=&offset=` | Officer | 200 | 400, 401, 403 |
| PATCH | `/members/:id/role` with `{"role":"member"\|"officer"}` | Officer | 200 | 400, 401, 403, 404, 409 |
| GET | `/audit-log?type=&limit=&before=<logId>` | Officer | 200 | 400, 401, 403 |

Other methods on these paths return 405. Errors are JSON:
`{"error": "<code>", ...}`.

Notes:

- Login returns the same `401 invalid_credentials` for a wrong password,
  an unknown email and a pending or rejected applicant.
- Repeating an approval or role change that already happened returns 200
  with `alreadyDecided` / `changed: false`. If the Auth update after a
  decision fails, the route returns 500 and the same request can be sent
  again.
- Access tokens last 15 minutes (`jwt_expiry = 900`). The frontend should
  let supabase-js refresh them.

## Security controls in this repository

| Control | Where |
|---|---|
| Row-level security on every table; no grants to `anon` or `authenticated` | all migrations |
| `EXECUTE` revoked from `public`, `anon`, `authenticated` on every function | all migrations |
| Public Auth sign-up disabled; accounts created only by the function | `supabase/config.toml` |
| Minimum password length 8 | `supabase/config.toml` |
| Pending applicants banned in Auth until approved | `membership-requests` route |
| Officer check against `profiles` on every officer request | `requireActiveOfficer` |
| Lockout: 5 failures lock for 15 minutes, counted before the password check | `login_lockout` migration, login route |
| Per-address limits: 5 requests per hour, 20 logins per 15 minutes | migrations, routes |
| Client addresses stored only as salted SHA-256 hashes | attempt tables |
| Last-officer protection with a roster lock | `member_role_change` migration |
| Append-only audit log for the secret key (no UPDATE, DELETE, TRUNCATE) | `members_search_audit_log` migration |
| Parameterised, wildcard-escaped member search | `search_members` |
| CORS only for origins in `FRONTEND_ORIGINS` | function |
| Body size limit (4 KB) and server-side input validation | function |

## Repository layout

```
supabase/
  config.toml                  local stack and Auth settings
  migrations/                  database schema, functions and grants
  functions/
    .env.example               secret names (copy to .env, never commit .env)
    membership-api/index.ts    the Edge Function
scripts/create-officer.sh      creates the first officer
tests/*.sh                     local API tests
```

## Secrets and configuration

| Name | Purpose |
|---|---|
| `MEMBERSHIP_IP_HASH_SALT` | Random secret used to hash client addresses before storing them |
| `FRONTEND_ORIGINS` | Comma-separated exact origins allowed by CORS |

Locally they go in `supabase/functions/.env`, which Git ignores. See
`supabase/functions/.env.example`. A hosted project would set them with
`supabase secrets set`. Supabase provides the project URL and keys to the
function automatically.

Never commit `.env` files or secret keys. The frontend may only hold the
publishable key.

## Local setup (Windows)

Requirements: Node.js, Git, Docker Desktop. In PowerShell use `npm.cmd`
and `npx.cmd` if script execution is blocked.

1. **Keep the local stack off the network.** Docker Desktop publishes the
   Supabase ports on all interfaces (`0.0.0.0`), and Docker's
   `host_binding_ipv4` network option and the daemon `"ip"` setting did
   not change that. In Windows Defender Firewall (`wf.msc`), set the
   inbound rules for `com.docker.backend.exe` to **Block the connection**.
   Local requests to `127.0.0.1` still work. Do not run the stack on
   public Wi-Fi without this.
2. Install dependencies: `npm install`
3. Create `supabase/functions/.env` from `.env.example` and fill in a
   random salt and your frontend's local origin.
4. Start the stack: `npx supabase start --network-id local-network`
   (create the network once with
   `docker network create -o com.docker.network.bridge.host_binding_ipv4=127.0.0.1 local-network`).
   The edge runtime reads `supabase/functions/.env` only at start, so
   restart after changing it.
5. Apply migrations to an existing local database: `npx supabase migration up`
6. Create the first officer: `bash scripts/create-officer.sh`
   (prompts for name, email and password; refuses if an officer exists).
7. Stop when finished: `npx supabase stop`

## Tests

Run from the repository root in Git Bash with the local stack running:

```
bash tests/membership-requests.sh
bash tests/officer-review.sh
bash tests/role-change.sh
bash tests/members-audit.sh
bash tests/login.sh
bash tests/cors.sh
```

Each script creates its own `*@example.test` users and removes them
afterwards. Last local run: 168 checks, all passing.

`tests/cors.sh` calls the function directly inside Docker because the
local gateway adds its own `Access-Control-Allow-Origin: *`.

## Known gaps and accepted risks

These are not fixed in code and should stay visible in the threat model.

- **Direct Auth sign-in skips the lockout counter.** Anyone can call
  Supabase Auth's password sign-in directly instead of `/auth/login`.
  Locked accounts are banned in Auth so that route is blocked too, but
  direct attempts are not counted. Auth's own per-address limit is the
  only control there.
- **Lockout can be triggered by others.** Anyone who knows an email can
  lock that account for 15 minutes.
- **Some responses reveal that an email exists:** 409 on a duplicate
  membership request and 423 on a locked account.
- **Role changes reach other services within 15 minutes.** This service
  checks roles in the database immediately; Events and Announcements rely
  on the token claim until it expires.
- **To check on a hosted project before relying on it:** which header
  carries the real client address (the code uses the last
  `X-Forwarded-For` entry), whether the hosted gateway adds its own CORS
  headers, and whether Auth's sign-in limit is shared by all logins made
  through the function.
- The 500 retry paths (Auth update failing after a database decision) and
  the 503 path (Auth's own limit) are not covered by tests.
