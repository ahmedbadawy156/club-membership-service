// The caller's address, and a salted hash of it for storage.
//
// On Lambda the address comes from API Gateway (requestContext.http.sourceIp),
// which the gateway sets itself, so a client cannot forge it with an
// X-Forwarded-For header. On your PC it is the socket address.
const crypto = require("crypto");
const { getSecrets } = require("./aws");

function clientIp(req) {
  const fromGateway = req.lambdaEvent?.requestContext?.http?.sourceIp;
  if (fromGateway) return fromGateway;
  return req.socket?.remoteAddress || "unknown";
}

async function clientIpHash(req) {
  const { ipHashSalt } = await getSecrets();
  return crypto.createHash("sha256").update(`${ipHashSalt}:${clientIp(req)}`).digest("hex");
}

module.exports = { clientIp, clientIpHash };
