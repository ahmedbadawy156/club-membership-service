// Generates the Membership service's secret values and writes them as JSON
// to the file given on the command line. deploy.sh stores that JSON in
// Secrets Manager and then deletes the file; nothing is printed.
//   node infra/make-secret.js <output-file>
//
//   jwtPrivateKey  RSA 2048 private key (PEM) that signs login tokens
//   jwtPublicKey   matching public key (PEM); Events and Announcements use it
//   ipHashSalt     random value used to hash client addresses before storing
const fs = require("fs");
const crypto = require("crypto");

const out = process.argv[2];
if (!out) {
  console.error("usage: node infra/make-secret.js <output-file>");
  process.exit(1);
}

const { privateKey, publicKey } = crypto.generateKeyPairSync("rsa", {
  modulusLength: 2048,
  publicKeyEncoding: { type: "spki", format: "pem" },
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
});

fs.writeFileSync(out, JSON.stringify({
  jwtPrivateKey: privateKey,
  jwtPublicKey: publicKey,
  ipHashSalt: crypto.randomBytes(32).toString("hex"),
}), { mode: 0o600 });
