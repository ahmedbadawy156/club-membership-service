const express = require("express");
const controller = require("../controllers/membershipRequests");
const { requireUser, requireActiveOfficer } = require("../middleware/auth");

const router = express.Router();

router.post("/", controller.submit);
router.get("/", requireUser, requireActiveOfficer, controller.list);
router.patch("/:id", requireUser, requireActiveOfficer, controller.review);

module.exports = router;
