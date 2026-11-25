// Settings from environment variables, with the names used by infra/deploy.sh.
module.exports = {
  tables: {
    users: process.env.USERS_TABLE || "ClubUsers",
    requests: process.env.REQUESTS_TABLE || "MembershipRequests",
    audit: process.env.AUDIT_TABLE || "AuditLog",
    rateLimits: process.env.RATE_LIMITS_TABLE || "RateLimits",
  },
  secretId: process.env.SECRET_ID || "club-membership/secrets",
  // Member notices: SNS topic (empty = do not publish) and the table the
  // notifier Lambda writes to.
  notifications: {
    topicArn: process.env.NOTIFICATIONS_TOPIC_ARN || "",
    table: process.env.NOTIFICATIONS_TABLE || "MemberNotifications",
  },
  limits: {
    requestsPerHourPerAddress: 5,
    maxPendingRequests: 200,
  },
};
