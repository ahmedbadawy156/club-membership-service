// Runs the SAME Express app on AWS Lambda (Lab 7 pattern).
// serverless-http turns the API Gateway event into an Express request and
// the Express response back into the answer Lambda returns.
const serverless = require("serverless-http");
const app = require("./app");

module.exports.handler = serverless(app, {
  // Keep the gateway event on the request, so the code can read values the
  // gateway sets itself (such as the caller's source address).
  request(req, event) {
    req.lambdaEvent = event;
  },
}); // Lambda setting: handler = lambda.handler
