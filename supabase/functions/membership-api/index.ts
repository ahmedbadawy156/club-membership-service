import { withSupabase } from "@supabase/server";

export default {
  fetch: withSupabase(
    { auth: ["user", "publishable"] },
    async (req) => {
      const path = new URL(req.url).pathname;

      if (req.method === "GET" && path.endsWith("/health")) {
        return Response.json({
          service: "membership",
          status: "ok",
        });
      }

      return Response.json(
        { error: "not_found" },
        { status: 404 },
      );
    },
  ),
};
