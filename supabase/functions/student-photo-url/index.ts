import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ success: false }, 405);

  try {
    const b = await req.json();
    const e = String(b?.enroll_no ?? "").trim();
    const d = String(b?.dob_password ?? "").trim();

    if (!e || !/^[0-9]{8}$/.test(d)) {
      return json({ success: false }, 400);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      return json({ success: false }, 503);
    }

    const sb = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
    });

    const rate = await sb.rpc("consume_student_login_attempt", {
      p_login_key: "photo:" + e.toUpperCase(),
      p_max_attempts: 6,
      p_window_seconds: 600,
    });

    if (rate.error) {
      console.error("student photo rate-limit check failed:", rate.error.message);
      return json({ success: false }, 503);
    }

    if (rate.data?.allowed !== true) {
      return json({
        success: false,
        code: "RATE_LIMIT",
        retry_after_seconds: Number(rate.data?.retry_after_seconds || 600),
      }, 429);
    }

    const day = +d.slice(0, 2);
    const month = +d.slice(2, 4);
    const year = +d.slice(4, 8);
    const dt = new Date(Date.UTC(year, month - 1, day));

    if (
      dt.getUTCFullYear() !== year ||
      dt.getUTCMonth() !== month - 1 ||
      dt.getUTCDate() !== day
    ) {
      return json({ success: false }, 401);
    }

    const iso =
      year +
      "-" +
      String(month).padStart(2, "0") +
      "-" +
      String(day).padStart(2, "0");

    const { data: s, error } = await sb
      .from("student_roster")
      .select("id,enroll_no,dob,status,photo_path")
      .eq("school_code", "ashiana")
      .ilike("enroll_no", e)
      .eq("status", "ACTIVE")
      .eq("dob", iso)
      .maybeSingle();

    if (error || !s) {
      return json({ success: false }, 401);
    }

    await sb.rpc("clear_student_login_attempt", {
      p_login_key: "photo:" + e.toUpperCase(),
    });

    if (!s.photo_path) {
      return json({ success: true, photo_url: "" });
    }

    const q = await sb.storage
      .from("student-photos")
      .createSignedUrl(s.photo_path, 86400);

    if (q.error || !q.data?.signedUrl) {
      return json({ success: false, photo_url: "" }, 404);
    }

    return json({ success: true, photo_url: q.data.signedUrl });
  } catch (err) {
    console.error("student-photo-url error:", err);
    return json({ success: false }, 500);
  }
});
