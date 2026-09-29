import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "https://esm.sh/@supabase/supabase-js@2/cors";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });


Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ error: "Server configuration is missing." }, 500);
  }

  const authorization = req.headers.get("Authorization") || "";
  const token = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
  if (!token) return json({ error: "Authentication required." }, 401);

  const client = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
  });

  try {
    // Resolve identity from Supabase Auth, never from caller-supplied fields or JWT metadata.
    const { data: authData, error: authError } = await client.auth.getUser(token);
    const user = authData?.user;
    if (authError || !user?.id || !user.email) {
      return json({ error: "Invalid or expired session." }, 401);
    }
    if (!user.email_confirmed_at) {
      return json({ error: "A verified account is required." }, 403);
    }
    const { data: platformAdmin, error: platformAdminError } = await client
      .from("platform_admins")
      .select("user_id")
      .eq("user_id", user.id)
      .eq("active", true)
      .maybeSingle();
    if (platformAdminError || !platformAdmin) {
      return json({ error: "Platform approver access is required." }, 403);
    }

    const body = await req.json().catch(() => null);
    const applicationId = typeof body?.application_id === "string" ? body.application_id.trim() : "";
    const decision = body?.decision;
    const reviewNote = typeof body?.review_note === "string" ? body.review_note.trim().slice(0, 1000) : null;

    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(applicationId)) {
      return json({ error: "A valid application ID is required." }, 400);
    }
    if (decision !== "approve" && decision !== "reject") {
      return json({ error: "Decision must be approve or reject." }, 400);
    }

    const { data, error } = await client.rpc("review_school_application", {
      p_application_id: applicationId,
      p_decision: decision,
      p_reviewer_id: user.id,
      p_review_note: reviewNote,
    });
    if (error) {
      const conflict = error.code === "23505" || error.code === "55000";
      return json({ error: conflict ? "Application cannot be processed in its current state." : "Application review failed." }, conflict ? 409 : 500);
    }

    return json({ success: true, result: data });
  } catch (_error) {
    return json({ error: "Application review failed." }, 500);
  }
});
