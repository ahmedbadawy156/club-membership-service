// Test-only Lambda function. tests/iam.sh deploys it with the SAME IAM role
// as club-membership-api, runs it once and deletes it. It tries calls the
// role should allow and calls it should not, and reports each outcome.
const {
  DynamoDBClient, ScanCommand, ListTablesCommand, DeleteItemCommand, PutItemCommand, UpdateItemCommand,
} = require("@aws-sdk/client-dynamodb");
const {
  SecretsManagerClient, GetSecretValueCommand, CreateSecretCommand,
} = require("@aws-sdk/client-secrets-manager");

const db = new DynamoDBClient({});
const sm = new SecretsManagerClient({});

async function attempt(name, fn) {
  try {
    await fn();
    return [name, "allowed"];
  } catch (e) {
    return [name, e.name === "AccessDeniedException" ? "denied" : `error:${e.name}`];
  }
}

exports.handler = async () => Object.fromEntries(await Promise.all([
  attempt("scan ClubUsers", () => db.send(new ScanCommand({ TableName: "ClubUsers", Select: "COUNT" }))),
  attempt("put AuditLog", () => db.send(new PutItemCommand({
    TableName: "AuditLog",
    Item: { logId: { S: "iam-probe" }, feed: { S: "probe" }, eventType: { S: "probe" }, sortKey: { S: "0" } },
  }))),
  attempt("update AuditLog", () => db.send(new UpdateItemCommand({
    TableName: "AuditLog", Key: { logId: { S: "iam-probe" } },
    UpdateExpression: "SET eventType = :t", ExpressionAttributeValues: { ":t": { S: "tampered" } },
  }))),
  attempt("delete AuditLog", () => db.send(new DeleteItemCommand({ TableName: "AuditLog", Key: { logId: { S: "iam-probe" } } }))),
  attempt("scan RateLimits", () => db.send(new ScanCommand({ TableName: "RateLimits", Select: "COUNT" }))),
  attempt("list tables", () => db.send(new ListTablesCommand({}))),
  attempt("read own secret", () => sm.send(new GetSecretValueCommand({ SecretId: "club-membership/secrets" }))),
  attempt("create a secret", () => sm.send(new CreateSecretCommand({ Name: "iam-probe-should-fail", SecretString: "x" }))),
]));
