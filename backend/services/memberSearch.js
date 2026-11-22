// Member search for officers.
//
// The club is small, so the table is read and filtered in code. The search
// text is only ever compared with String.includes, never placed in a query
// or filter expression, so characters like %, _ or "role = officer" are just
// text and cannot change what is matched.
const { ScanCommand } = require("@aws-sdk/lib-dynamodb");
const { db } = require("../lib/aws");
const config = require("../lib/config");

async function allUsers() {
  const items = [];
  let ExclusiveStartKey;
  do {
    const res = await db.send(new ScanCommand({ TableName: config.tables.users, ExclusiveStartKey }));
    items.push(...(res.Items || []));
    ExclusiveStartKey = res.LastEvaluatedKey;
  } while (ExclusiveStartKey);
  return items.filter((u) => !u.userId.startsWith("META#"));
}

// status: "active" | "inactive" | "all". Returns { members, total }.
async function searchMembers({ search, status, limit, offset }) {
  const needle = (search || "").toLowerCase();
  const matched = (await allUsers())
    .filter((u) => status === "all" || (status === "active" ? u.active === true : u.active !== true))
    .filter((u) => !needle
      || (u.fullName || "").toLowerCase().includes(needle)
      || (u.emailLower || "").includes(needle))
    .sort((a, b) => (a.fullName || "").toLowerCase().localeCompare((b.fullName || "").toLowerCase())
      || a.userId.localeCompare(b.userId));

  return {
    members: matched.slice(offset, offset + limit).map((u) => ({
      userId: u.userId,
      fullName: u.fullName,
      email: u.email,
      role: u.role,
      active: u.active === true,
      createdAt: u.createdAt,
    })),
    total: matched.length,
  };
}

module.exports = { searchMembers };
