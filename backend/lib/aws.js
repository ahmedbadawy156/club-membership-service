// AWS clients. No keys in the code: on Lambda the IAM role gives permission;
// on your PC the "floci" AWS profile does (see backend/.env.example).
const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient } = require("@aws-sdk/lib-dynamodb");
const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");
const config = require("./config");

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
  marshallOptions: { removeUndefinedValues: true },
});

const secretsClient = new SecretsManagerClient({});
let secretsPromise = null;

// The secret JSON { jwtPrivateKey, jwtPublicKey, ipHashSalt }, read once per
// cold start and kept in memory. Never logged.
function getSecrets() {
  if (!secretsPromise) {
    secretsPromise = secretsClient
      .send(new GetSecretValueCommand({ SecretId: config.secretId }))
      .then((res) => JSON.parse(res.SecretString))
      .catch((err) => {
        secretsPromise = null; // retry on the next request
        throw err;
      });
  }
  return secretsPromise;
}

module.exports = { db, getSecrets };
