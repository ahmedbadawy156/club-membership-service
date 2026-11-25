# Security tests: proposal map (Membership service)

How the Phase 1 proposal's security tests (Section 6.5, T1 to T10) and
threats (Section 6.4) are covered for the Membership service. Every check
runs against the Floci deployment; results are saved in
`evidence/test-results.txt` by `bash infra/collect-evidence.sh`.

Events and Announcements parts of T1 to T4, T6 and T8 belong to those
services and are tested in their own repositories.

| Proposal test | Threat | What is checked here | Script: check name |
|---|---|---|---|
| T1 Unauthenticated access | 4 | Officer routes without a token or with a malformed one get 401 | `officer-review.sh`: "no token", "malformed token"; `role-change.sh`: "no token"; `members-audit.sh`: "members: no token", "audit-log: no token" |
| T2 Unauthorized role | 4 | A member's token gets 403 on review, role change, member list and audit log; nothing changes | `officer-review.sh`: "member token: approve", "request D still pending…"; `role-change.sh`: "member token"; `members-audit.sh`: "members: member token" |
| T2 (stale role) | 3 | A token that still says officer after demotion is refused by Membership at once | `role-change.sh`: "but Membership refuses it at once"; `officer-review.sh`: "token says officer but database says member" |
| T3 Invalid input | 5 | Missing fields, bad email, short or over-72-byte password, arrays, invalid JSON, bodies over 4 KB, bad ids, bad query values: 400 or 413, nothing stored | `membership-requests.sh` (9 checks); `officer-review.sh`: "invalid request id", "invalid decision"; `members-audit.sh`: "invalid …" |
| T4 Ownership | 4 | Membership has no per-member records to change; the matching rule is that only active officers act, checked in the database on every request (deactivated officer refused) | `officer-review.sh`: "deactivated officer: …" |
| T5 Secret exposure | 7, 8 | Git history has no private key, `.env` or generated secret file; the S3 site has no key; log lines never contain query strings; responses never contain password hashes | `infra/collect-evidence.sh` (secret scan); `check.sh`: "log lines never contain a query string"; `members-audit.sh`: "no password hash anywhere" |
| T6 Token tampering | 2 | Expired, wrong-key, `alg: none` and HS256-with-public-key tokens all get 401 | `officer-review.sh`: "officer token with expired / wrongkey / none / hs256 …" |
| T7 Brute force | 1 | Five wrong passwords, then the correct one: 423 with Retry-After; 5 `login_failure` + 1 `account_locked`; 10 simultaneous guesses give five 401 and five 423 | `login.sh` |
| T8 Injection / XSS | 5 | Script-like names stored exactly as text; `%`, `_` and filter-like search text are plain text; the frontend shows them with `textContent` (browser test) | `membership-requests.sh`: "stored exactly as typed"; `members-audit.sh`: "search % …", "filter-like search text …" |
| T9 CORS and route exposure | 10 | Unlisted methods and paths stopped by API Gateway (404, no log line); a foreign Origin gets no Access-Control-Allow-Origin | `check.sh`; `membership-requests.sh`: "PUT not listed…", "preflight from another origin…" |
| T10 Abuse control | 6 | 6th request per hour from one address 429 (forged X-Forwarded-For does not help); duplicate email 409; 21st login per 15 minutes 429 | `membership-requests.sh`; `login.sh`: "21st attempt…" |
| Threat 9 IAM least privilege | 9 | With Floci IAM enforcement on, the role may read users and its secret and add audit entries, and is refused editing or deleting audit entries, other tables, ListTables and creating secrets | `iam.sh` |
| Messaging (SNS, EventBridge) | 4, 5, 9 | Members read only their own notices (an id in the query is ignored); the topic accepts only this account and the club bus rule; the notifier drops unknown sources, bad roles and non-JSON and never logs bodies; duplicate deliveries store one notice; no notice carries an email; the notifier's role may only write notices | `notifications.sh`; `iam.sh`: "notifier role: …" |
| Threat 11 Rebuild | 11 | `infra/deploy.sh` rebuilds tables, secret, role, function and routes on a clean Floci and is safe to run again | `infra/deploy.sh`, `check.sh` |
