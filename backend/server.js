// Runs the Express app on your PC: npm run dev  ->  http://127.0.0.1:3000
// Listens on 127.0.0.1 only, so other devices on the network cannot reach it.
const app = require("./app");

const PORT = Number(process.env.PORT) || 3000;

app.listen(PORT, "127.0.0.1", () => {
  console.log(`Membership API listening on http://127.0.0.1:${PORT} (${process.env.NODE_ENV || "development"})`);
});
