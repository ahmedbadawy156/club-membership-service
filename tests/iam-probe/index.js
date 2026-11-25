// Test-only Lambda function. tests/iam.sh deploys it with the SAME IAM role
// as club-membership-api (and again with the notifier's role), runs it once
// and deletes it. It tries calls the role should allow and calls it should
// not, and reports each outcome.
const {
  DynamoDBClient, ScanCommand, ListTablesCommand, DeleteItemCommand, PutItemCommand, UpdateItemCommand, QueryCommand,
} = require("@aws-sdk/client-dynamodb");
const {
  SecretsManagerClient, GetSecretValueCommand, CreateSecretCommand,
} = require("@aws-sdk/client-secrets-manager");
const { SNSClient, PublishCommand, SubscribeCommand } = require("@aws-sdk/client-sns");
const { EventBridgeClient, PutEventsCommand } = require("@aws-sdk/client-eventbridge");

const db = new DynamoDBClient({});
const sm = new SecretsManagerClient({});
const sns = new SNSClient({});
const eb = new EventBridgeClient({});
const TOPIC = "arn:aws:sns:us-east-1:000000000000:club-member-notifications";
// A notice for a user id that does not exist; deleted by tests/iam.sh.
const NOTICE_KEY = { userId: { S: "iam-probe" }, sortKey: { S: "iam-probe" } };

async function attempt(name, fn) {
  try {
    await fn();
    return [name, "allowed"];
  } catch (e) {
    const denied = ["AccessDeniedException", "AccessDenied", "AuthorizationError", "AuthorizationErrorException"];
    return [name, denied.includes(e.name) || e.Code === "AccessDenied" ? "denied" : `error:${e.name}`];
  }
}

// PutEvents reports a refused entry in the answer as well as by throwing.
async function putEvents() {
  const r = await eb.send(new PutEventsCommand({ Entries: [{
    EventBusName: "campus-club-bus", Source: "club.iam-probe", DetailType: "IamProbe", Detail: "{}",
  }] }));
  if (r.FailedEntryCount) { const e = new Error(r.Entries[0].ErrorCode); e.name = r.Entries[0].ErrorCode; throw e; }
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
  attempt("query MemberNotifications", () => db.send(new QueryCommand({
    TableName: "MemberNotifications", KeyConditionExpression: "userId = :u",
    ExpressionAttributeValues: { ":u": { S: "iam-probe" } }, Limit: 1,
  }))),
  attempt("put MemberNotifications", () => db.send(new PutItemCommand({ TableName: "MemberNotifications", Item: NOTICE_KEY }))),
  attempt("delete MemberNotifications", () => db.send(new DeleteItemCommand({ TableName: "MemberNotifications", Key: { userId: { S: "nobody" }, sortKey: { S: "nobody" } } }))),
  attempt("scan MemberNotifications", () => db.send(new ScanCommand({ TableName: "MemberNotifications", Select: "COUNT" }))),
  // A message the notifier drops (unknown source), so nobody gets a notice.
  attempt("publish to the notifications topic", () => sns.send(new PublishCommand({ TopicArn: TOPIC, Message: '{"id":"iam-probe","source":"club.iam-probe","detail":{}}' }))),
  attempt("subscribe to the notifications topic", () => sns.send(new SubscribeCommand({ TopicArn: TOPIC, Protocol: "sqs", Endpoint: "arn:aws:sqs:us-east-1:000000000000:iam-probe" }))),
  attempt("put event on the club bus", putEvents),
]));
