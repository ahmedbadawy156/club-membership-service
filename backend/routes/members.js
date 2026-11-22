const express = require("express");
const controller = require("../controllers/members");
const { requireUser, requireActiveOfficer } = require("../middleware/auth");

const router = express.Router();

router.patch("/:id/role", requireUser, requireActiveOfficer, controller.changeRole);

module.exports = router;
