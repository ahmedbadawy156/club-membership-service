// Settings from environment variables, with the names used by infra/deploy.sh.
module.exports = {
  tables: {
    users: process.env.USERS_TABLE || "ClubUsers",
    requests: process.env.REQUESTS_TABLE || "MembershipRequests",
    audit: process.env.AUDIT_TABLE || "AuditLog",
    rateLimits: process.env.RATE_LIMITS_TABLE || "RateLimits",
  },
  secretId: process.env.SECRET_ID || "club-membership/secrets",
  limits: {
    requestsPerHourPerAddress: 5,
    maxPendingRequests: 200,
  },
};
