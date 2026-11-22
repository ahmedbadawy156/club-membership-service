const express = require("express");
const controller = require("../controllers/auth");

const router = express.Router();

router.post("/login", controller.signIn);
router.get("/public-key", controller.publicKey);

module.exports = router;
