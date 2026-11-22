// Club members and officers in the ClubUsers table.
const { GetCommand } = require("@aws-sdk/lib-dynamodb");
const { db } = require("../lib/aws");
const config = require("../lib/config");

const OFFICER_COUNTER_KEY = "META#officers";

async function getUser(userId) {
  if (!userId || userId.startsWith("META#")) return null;
  const res = await db.send(new GetCommand({ TableName: config.tables.users, Key: { userId } }));
  return res.Item || null;
}

// A transaction item that succeeds only while `userId` is an active officer.
function activeOfficerCheck(userId) {
  return {
    ConditionCheck: {
      TableName: config.tables.users,
      Key: { userId },
      ConditionExpression: "#r = :officer AND active = :yes",
      ExpressionAttributeNames: { "#r": "role" },
      ExpressionAttributeValues: { ":officer": "officer", ":yes": true },
    },
  };
}

module.exports = { getUser, activeOfficerCheck, OFFICER_COUNTER_KEY };
