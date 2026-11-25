const express = require("express");
const controller = require("../controllers/notifications");
const { requireUser } = require("../middleware/auth");

const router = express.Router();

router.get("/", requireUser, controller.listMine);
router.post("/seen", requireUser, controller.markSeen);

module.exports = router;
