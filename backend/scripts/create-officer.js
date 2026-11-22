// Creates the club's FIRST officer. Run through infra/create-officer.sh,
// which asks for the details. Reads OFFICER_NAME, OFFICER_EMAIL and
// OFFICER_PASSWORD from the environment; never prints the password.
//
// One transaction: claim the email, create the active officer, set the
// officer counter to 1 (only if no officer exists yet) and write the audit
// entry. If any part fails, nothing is created.
const crypto = require("crypto");
const { GetCommand, TransactWriteCommand } = require("@aws-sdk/lib-dynamodb");
const { db } = require("../lib/aws");
const config = require("../lib/config");
const validate = require("../lib/validate");
const { hashPassword } = require("../lib/passwords");
const { OFFICER_COUNTER_KEY } = require("../services/users");
const audit = require("../services/audit");

function fail(message) {
  console.error(message);
  process.exit(1);
}

(async () => {
  const fullName = validate.fullName(process.env.OFFICER_NAME);
  const email = validate.email(process.env.OFFICER_EMAIL);
  const password = validate.newPassword(process.env.OFFICER_PASSWORD);
  if (!fullName) fail("Name must be 2 to 100 characters.");
  if (!email) fail("Email address is not valid.");
  if (!password) fail("Password must be 8 to 72 characters.");

  const counter = await db.send(new GetCommand({
    TableName: config.tables.users, Key: { userId: OFFICER_COUNTER_KEY },
  }));
  if ((counter.Item?.count || 0) > 0) fail("An officer already exists. Use the role endpoints instead.");

  const userId = crypto.randomUUID();
  const emailLower = email.toLowerCase();
  const now = new Date().toISOString();
  const passwordHash = await hashPassword(password);

  try {
    await db.send(new TransactWriteCommand({
      TransactItems: [
        {
          Put: {
            TableName: config.tables.requests,
            Item: { requestId: `EMAIL#${emailLower}`, claimFor: "bootstrap", userId, createdAt: now },
            ConditionExpression: "attribute_not_exists(requestId)",
          },
        },
        {
          Put: {
            TableName: config.tables.users,
            Item: {
              userId, fullName, email, emailLower, passwordHash,
              role: "officer", active: true, failedLogins: 0, createdAt: now,
            },
            ConditionExpression: "attribute_not_exists(userId)",
          },
        },
        {
          Put: {
            TableName: config.tables.users,
            Item: { userId: OFFICER_COUNTER_KEY, count: 1 },
            ConditionExpression: "attribute_not_exists(userId) OR #c = :zero",
            ExpressionAttributeNames: { "#c": "count" },
            ExpressionAttributeValues: { ":zero": 0 },
          },
        },
        audit.entryPut({ eventType: "role_changed", targetId: userId, metadata: { reason: "bootstrap", newRole: "officer" } }),
      ],
    }));
  } catch (err) {
    const reasons = err.CancellationReasons || [];
    if (reasons[0]?.Code === "ConditionalCheckFailed") fail("That email is already used by a member or a request.");
    if (reasons[2]?.Code === "ConditionalCheckFailed") fail("An officer already exists. Use the role endpoints instead.");
    fail(`Could not create the officer (${err.name}).`);
  }

  console.log(`Officer created: ${emailLower} (user id ${userId})`);
})();
