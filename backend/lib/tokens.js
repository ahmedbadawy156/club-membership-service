// Login tokens: RS256 JWTs signed with the private key from Secrets Manager.
// Events and Announcements verify them with the public key only.
const jwt = require("jsonwebtoken");
const { getSecrets } = require("./aws");

const ISSUER = "club-membership";
const AUDIENCE = "campus-club";
const LIFETIME_SECONDS = 15 * 60;

// { sub, role, name } -> { token, expiresAt, expiresIn }
async function signToken(user) {
  const { jwtPrivateKey } = await getSecrets();
  const now = Math.floor(Date.now() / 1000);
  const token = jwt.sign(
    { role: user.role, name: user.fullName },
    jwtPrivateKey,
    { algorithm: "RS256", subject: user.userId, issuer: ISSUER, audience: AUDIENCE, expiresIn: LIFETIME_SECONDS },
  );
  return { token, expiresIn: LIFETIME_SECONDS, expiresAt: now + LIFETIME_SECONDS };
}

// Returns the verified claims, or null for any invalid, expired, unsigned or
// foreign token. Only RS256 is accepted, so "alg: none" and HS256 tricks fail.
async function verifyToken(token) {
  const { jwtPublicKey } = await getSecrets();
  try {
    return jwt.verify(token, jwtPublicKey, { algorithms: ["RS256"], issuer: ISSUER, audience: AUDIENCE });
  } catch {
    return null;
  }
}

async function publicKey() {
  return (await getSecrets()).jwtPublicKey;
}

module.exports = { signToken, verifyToken, publicKey, ISSUER, AUDIENCE, LIFETIME_SECONDS };
