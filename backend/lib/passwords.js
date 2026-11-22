// Password hashing with bcryptjs (pure JavaScript, so the same code runs on
// Windows and on Lambda's Linux without a compiled module).
const bcrypt = require("bcryptjs");

const ROUNDS = 10;

const hashPassword = (plain) => bcrypt.hash(plain, ROUNDS);
const checkPassword = (plain, hash) => bcrypt.compare(plain, hash);

module.exports = { hashPassword, checkPassword };
