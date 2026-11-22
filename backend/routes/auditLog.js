const express = require("express");
const controller = require("../controllers/auditLog");
const { requireUser, requireActiveOfficer } = require("../middleware/auth");

const router = express.Router();

router.get("/", requireUser, requireActiveOfficer, controller.list);

module.exports = router;
