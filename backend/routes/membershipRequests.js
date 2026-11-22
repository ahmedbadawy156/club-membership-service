const express = require("express");
const controller = require("../controllers/membershipRequests");

const router = express.Router();

router.post("/", controller.submit);

module.exports = router;
