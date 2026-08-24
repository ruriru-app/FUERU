// FUERU auth-handoff Edge Function v1.0
// Creates a one-time Supabase token for transferring an authenticated Safari
// session to the installed iOS web app. The token is returned only to the
// currently authenticated user and is never logged or stored by this function.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "jsr:@supabase/server@^1";

const ALLOWED_ORIGIN = "https://ruriru-app.github.io";

const corsHeaders = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
  "Vary": "Origin",
};

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

const handleAuthenticated = withSupabase(
  { auth: "user" },
  async (req, ctx) => {
    if (req.method !== "POST") return json({ ok: false, code: "method_not_allowed" }, 405);

    const requestOrigin = req.headers.get("origin");
    if (requestOrigin && requestOrigin !== ALLOWED_ORIGIN) {
      return json({ ok: false, code: "origin_not_allowed" }, 403);
    }

    const contentLength = Number(req.headers.get("content-length") || "0");
    if (contentLength > 1024) return json({ ok: false, code: "request_too_large" }, 413);

    let input: { action?: unknown };
    try {
      input = await req.json();
    } catch {
      return json({ ok: false, code: "invalid_json" }, 400);
    }
    if (input.action !== "create") return json({ ok: false, code: "invalid_action" }, 400);

    const userId = String(ctx.jwtClaims?.sub || "");
    if (!/^[0-9a-f-]{36}$/i.test(userId)) {
      return json({ ok: false, code: "invalid_user" }, 401);
    }

    const { data: userResult, error: userError } = await ctx.supabase.auth.getUser();
    const user = userResult?.user;
    if (userError || !user || user.id !== userId || !user.email) {
      return json({ ok: false, code: "invalid_user" }, 401);
    }

    const { data: linkData, error: linkError } = await ctx.supabaseAdmin.auth.admin.generateLink({
      type: "magiclink",
      email: user.email,
      options: {
        redirectTo: "https://ruriru-app.github.io/FUERU/",
      },
    });
    const tokenHash = linkData?.properties?.hashed_token;
    if (linkError || typeof tokenHash !== "string" || tokenHash.length < 20 || tokenHash.length > 500) {
      return json({ ok: false, code: "handoff_failed" }, 500);
    }

    return json({ ok: true, token_hash: tokenHash });
  },
);

export default {
  async fetch(req: Request): Promise<Response> {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
    return handleAuthenticated(req);
  },
};
