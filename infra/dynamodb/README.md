# DynamoDB tables (Membership service)

All tables are on-demand (PAY_PER_REQUEST). Only the keys and index keys are
declared; the code validates every other field.

| Table | Key | Indexes | Items |
|---|---|---|---|
| ClubUsers | `userId` | `EmailIndex` (emailLower) | One item per approved member or officer; `META#officers` holds the active-officer count |
| MembershipRequests | `requestId` | `StatusIndex` (status, submittedAt) | One item per request; `EMAIL#<email>` items claim each email once, so no email can apply twice |
| AuditLog | `logId` | `FeedIndex` (feed, sortKey), `TypeIndex` (eventType, sortKey) | Append-only entries; `sortKey` = createdAt#logId gives newest-first paging |
| RateLimits | `limitKey` | none | Counters per hashed address and time window; TTL on `expiresAt` removes old ones |

Passwords are stored only as bcrypt hashes. Client addresses are stored
only as salted SHA-256 hashes.
