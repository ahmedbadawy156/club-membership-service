const express = require("express");
const controller = require("../controllers/members");
const { requireUser, requireActiveOfficer } = require("../middleware/auth");

const router = express.Router();

router.get("/", requireUser, requireActiveOfficer, controller.list);
router.patch("/:id/role", requireUser, requireActiveOfficer, controller.changeRole);

module.exports = router;
