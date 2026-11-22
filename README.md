# club-membership-service

Membership and Roles service for Team 10's Campus Club Management project
(Cloud Computing and Cloud Security, 26CSCN29H). Owner: Ahmed Emad Badawy.

Node.js + Express, run on AWS Lambda behind Amazon API Gateway, deployed to
**Floci** (a local AWS emulator), following the Lab 7 pattern.

> **Status:** work in progress on branch `feature/express-floci`.
> Only `GET /api/health` exists so far. Nothing is deployed to real AWS.
> The earlier Supabase version is on branch `feature/membership-workflow`.

## Run it

Requirements: Docker Desktop, Node.js, AWS CLI v2 with a `floci` profile
(keys `test`/`test`, region `us-east-1`, endpoint `http://localhost:4566`).
Run commands in Git Bash from the repository root.

```
docker compose -f infra/floci/docker-compose.yml up -d   # start Floci
bash infra/deploy.sh                                      # deploy or update
bash infra/check.sh                                       # check the deployment
```

Only one Floci runs at a time. If the Lab 7 Floci is running, stop it first
with `docker compose -f <lab folder>/infra/floci/docker-compose.yml down`.

Run the API on your PC instead (port 3000, this PC only):

```
cd backend && npm install && npm run dev
```

## Layout

| Path | What it is |
|---|---|
| `backend/app.js` | The Express app (middleware and routes) |
| `backend/server.js` | Runs the app on your PC |
| `backend/lambda.js` | Runs the same app on Lambda (`serverless-http`) |
| `backend/middleware/` | Request log (no bodies or query strings), errors |
| `infra/floci/docker-compose.yml` | Floci, with IAM enforcement on |
| `infra/iam/` | Trust policy and least-privilege policy for the function's role |
| `infra/routes.txt` | API Gateway route allow-list |
| `infra/deploy.sh`, `infra/check.sh` | Deploy to Floci and check the result |

If `*.localhost.floci.io` cannot be resolved (no internet), add
`127.0.0.1 <api-id>.execute-api.localhost.floci.io` to the Windows hosts file.
