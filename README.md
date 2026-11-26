# club-membership-service

Membership and Roles service for Team 10's Campus Club Management project
(Cloud Computing and Cloud Security, 26CSCN29H). Owner: **Ahmed Emad Badawy**.

Node.js + Express, run on **AWS Lambda** behind **Amazon API Gateway**, with
**Amazon DynamoDB**, **AWS Secrets Manager**, **Amazon SNS**, **Amazon
EventBridge**, **AWS IAM** and **Amazon CloudWatch Logs**, deployed to **Floci** (a local AWS emulator) following
the Lab 7 pattern. The same Express app also runs on a PC with `npm run dev`.

> **Status:** all seven endpoints from the Phase 1 proposal are built and
> tested on Floci, plus member notifications (SNS). Nothing is deployed to real AWS. The earlier Supabase
> prototype is kept on branch `feature/membership-workflow` for reference.

## What the service does

- Visitors ask to join with a chosen password. No account exists until an
  officer approves the request.
- Officers list requests and approve or reject each one once. Approval
  creates the member account.
- Officers change roles between member and officer. The club always keeps at
  least one active officer.
- Members sign in and receive a 15-minute token. Five failed attempts lock
  the account for 15 minutes.
- Officers search members and read an append-only audit log.
- The Events and Announcements services verify tokens with the public key
  this service publishes.
- Members get notices: welcome on approval, role changes, a seat that opened
  up for them, and events they signed up for that were cancelled. The last two
  come from the Events service through the club's EventBridge bus.

## Architecture

```
Browser (S3 site club-web)
   │  fetch + Bearer token
   ▼
API Gateway  club-membership-http-api   ← route allow-list (infra/routes.txt)
   │  AWS_PROXY, payload 2.0
   ▼
Lambda  club-membership-api  (Express via serverless-http, Node.js 24)
   ├── DynamoDB      ClubUsers · MembershipRequests · AuditLog · RateLimits
   ├── Secrets Mgr   club-membership/secrets (RS256 key pair, address-hash salt)
   ├── SNS           club-member-notifications  (approval, role change)
   └── CloudWatch    /aws/lambda/club-membership-api  (one line per request)
IAM role  club-membership-role: only the resources above (infra/iam/)

Member notices
  Membership API ──────────────────────────┐
  Events ─► EventBridge bus campus-club-bus │
            rule club-events-to-notifications (EventCancelled, SeatPromoted)
                                           ▼
            SNS topic club-member-notifications  (topic policy: this account + that rule)
                                           ▼
            Lambda club-membership-notifier  (own role: PutItem on one table)
                                           ▼
            DynamoDB MemberNotifications (TTL 60 days) ◄── GET /api/notifications
```

## AWS services used (8)

| Service | Resource | Purpose |
|---|---|---|
| Lambda | `club-membership-api`, `club-membership-notifier` | Runs the Express app; stores notices from SNS |
| API Gateway (HTTP API) | `club-membership-http-api` | Public address; only listed routes reach the code |
| DynamoDB | 5 tables (`infra/dynamodb/`) | Users, requests, audit log, rate-limit counters, member notices (TTL) |
| Secrets Manager | `club-membership/secrets` | Token signing key pair and address-hash salt |
| SNS | `club-member-notifications` | Fans member notices out to the notifier; topic policy allows only this account and the bus rule |
| EventBridge | rule `club-events-to-notifications` on `campus-club-bus` | Forwards EventCancelled and SeatPromoted from Events to the topic |
| IAM | `club-membership-role`, `club-membership-notifier-role` | Least-privilege permissions, enforced on Floci |
| CloudWatch Logs | `/aws/lambda/club-membership-api`, `.../club-membership-notifier` | Request logs (no bodies, no query strings); notice results (ids only); `FailedLogins` metric filter and the `club-failed-logins-burst` alarm (5 or more failed logins in 5 minutes) |

## Endpoints

Base address on Floci: `http://<api-id>.execute-api.localhost.floci.io:4566`.
Officer routes need `Authorization: Bearer <token>`. Errors are JSON:
`{"error": "<code>", ...}`.

| Method | Path | Who | Success | Errors |
|---|---|---|---|---|
| GET | `/api/health` | Public | 200 | |
| POST | `/api/auth/login` | Public | 200 | 400, 401, 403, 413, 423, 429 |
| GET | `/api/auth/public-key` | Public | 200 | |
| POST | `/api/membership-requests` | Public | 201 | 400, 403, 409, 413, 429 |
| GET | `/api/membership-requests?status=pending\|approved\|rejected` | Officer | 200 | 400, 401, 403 |
| PATCH | `/api/membership-requests/{id}` `{"decision":"approve"\|"reject"}` | Officer | 200 | 400, 401, 403, 404, 409 |
| GET | `/api/members?search=&status=active\|inactive\|all&limit=&offset=` | Officer | 200 | 400, 401, 403 |
| PATCH | `/api/members/{id}/role` `{"role":"member"\|"officer"}` | Officer | 200 | 400, 401, 403, 404, 409 |
| GET | `/api/audit-log?type=&limit=&before=<logId>` | Officer | 200 | 400, 401, 403 |
| GET | `/api/notifications?limit=1..50` | Signed in (own only) | 200 | 400, 401 |
| POST | `/api/notifications/seen` | Signed in (own only) | 204 | 401, 404 |

Any other method or path is refused by API Gateway with `404 {"message":"Not Found"}`
before the function runs.

### Token format (for Events and Announcements)

RS256 JWT, 15 minutes, no refresh token. Claims: `sub` (user id), `role`
(`member` or `officer`), `name`, `iss` = `club-membership`,
`aud` = `campus-club`. Verify with the key from `GET /api/auth/public-key`,
accept only RS256, and check issuer, audience and expiry. A role change
reaches other services when the old token expires (at most 15 minutes);
this service checks the current role in DynamoDB on every officer request.

## Business rules and how they hold under concurrency

| Rule | How |
|---|---|
| An email applies once | `EMAIL#<email>` claim item written in the same transaction as the request |
| A request is decided once | Transaction: request must still be `pending`, reviewer must still be an active officer |
| Approval creates exactly one account | Same transaction creates the user, moves the bcrypt hash and writes the audit entry |
| The last officer cannot be demoted | Transaction decrements `META#officers` only while it is above 1 |
| 5 failures lock for 15 minutes | Attempt counted before the password check with a conditional atomic update |
| 5 requests per hour, 20 logins per 15 minutes per address | Conditional atomic counters in `RateLimits` (TTL cleans up) |
| A notice is stored once, even if SNS delivers twice | Sort key built from the message's own id and time, written with `attribute_not_exists` |
| Members see only their own notices | The user id comes from the token; no id is read from the request |

## Security controls

| Control | Where |
|---|---|
| Passwords hashed with bcrypt; hash never returned | `lib/passwords.js`, explicit response fields |
| Tokens RS256 only, issuer and audience checked; private key only in Secrets Manager | `lib/tokens.js`, `infra/make-secret.js` |
| Officer routes re-read the current role and active flag | `middleware/auth.js` |
| Same 401 for wrong password, unknown email, pending or inactive account | `controllers/auth.js`, `services/login.js` |
| Input validation, 4 KB body limit, no user text in DynamoDB expressions | `lib/validate.js`, `app.js`, services |
| Client address from API Gateway only, stored as a salted hash | `lib/clientIp.js` |
| CORS only for `CORS_ORIGINS`, `Retry-After` exposed | `app.js` |
| Route allow-list at the gateway | `infra/routes.txt` |
| Least-privilege IAM; audit log append-only (no update or delete) | `infra/iam/membership-policy.json`, `tests/iam.sh` |
| Notifier has its own role (PutItem on MemberNotifications only); only the topic may invoke it; only this account and the bus rule may publish | `infra/iam/notifier-policy.json`, `infra/deploy.sh` |
| Notices carry ids and event titles, never emails; the notifier drops unknown sources and logs only message ids | `services/notifications.js`, `notifier.js` |
| Logs: method, path, status, time only | `middleware/requestLog.js` |
| No secrets in the repository; `.env` and generated files ignored | `.gitignore`, `infra/collect-evidence.sh` |

## Run it

Requirements: Docker Desktop, Node.js, AWS CLI v2 with a `floci` profile
(keys `test`/`test`, region `us-east-1`, endpoint `http://localhost:4566`).
Run in Git Bash from the repository root.

```
docker compose -f infra/floci/docker-compose.yml up -d   # start Floci (IAM enforcement on)
bash infra/deploy.sh                                      # tables, secret, roles, Lambdas, API, SNS, rule
bash infra/create-officer.sh                              # first officer (hidden password)
bash tests/run-all.sh                                     # every test suite
```

- Only one Floci runs at a time. Stop the Lab 7 Floci first if it is running.
- `infra/deploy.sh` can be run again: it creates what is missing and updates
  the rest. The secret is generated once and never written to the repository.
- To run the API on your PC against Floci: copy `backend/.env.example` to
  `backend/.env`, then `cd backend && npm install && npm run dev`.
- If `*.localhost.floci.io` cannot be resolved (no internet), add
  `127.0.0.1 <api-id>.execute-api.localhost.floci.io` to the Windows hosts file.

## Tests

| Script | Checks |
|---|---|
| `infra/check.sh` | Deployment: function, gateway routes, CORS, logs |
| `tests/membership-requests.sh` | Requests: validation, duplicates, races, limits |
| `tests/officer-review.sh` | Review, tokens (expired, wrong key, `alg: none`, HS256), create-officer |
| `tests/login.sh` | Lockout, simultaneous guesses, limits, public key |
| `tests/role-change.sh` | Roles, last officer, simultaneous demotions |
| `tests/members-audit.sh` | Search, audit log paging and filters |
| `tests/notifications.sh` | SNS wiring, notices from approvals, role changes and the bus, duplicates, dropped messages, own-only, unread/seen, end to end through Events |
| `tests/iam.sh` | Both roles' allowed and refused calls on Floci |

`bash tests/run-all.sh` runs them all. `bash infra/collect-evidence.sh`
saves the results and resource listings into `evidence/`. See
`docs/security-tests.md` for how they map to the proposal's security tests.

## Repository layout

```
backend/        Express app (app.js, server.js, lambda.js), routes, controllers,
                services (DynamoDB), middleware, lib, scripts
infra/          Floci compose file, DynamoDB tables, IAM policies, route list,
                deploy / check / create-officer / collect-evidence scripts
tests/          test suites, helpers, IAM probe function
docs/           security test map
evidence/       saved test results and Floci resource listings
```

## Known gaps and accepted risks

- Anyone who knows an email can lock that account for 15 minutes.
- `409` on a duplicate request and `423` on a locked account reveal that an
  email exists.
- Tokens cannot be revoked before they expire (15 minutes); role changes reach
  other services within that time.
- Rate limits use fixed windows, so up to twice the limit can pass around a
  window boundary.
- On Floci every bucket shares the origin `http://localhost:4566`, so CORS
  cannot tell the club site from another bucket; IAM is checked only when the
  Floci enforcement switch is on (it is in `infra/floci/docker-compose.yml`).
- Notices are best effort: if SNS is down when an officer approves someone,
  the approval stands and the failure is logged, but no notice is sent.
- The notifier has no dead-letter queue: a notice that still fails after
  Lambda's two automatic retries is lost (it is logged).
- Floci is an emulator on one laptop: no provider guarantees, and data lives
  in a Docker volume (`club-floci-data`).
