// student-photo-url — returns a short-lived signed URL for a student's photo.
//
// Fixes:
//  * enroll_no is matched EXACTLY (case-insensitive) — LIKE wildcards are escaped,
//    so "%" / "_" patterns can no longer match other students or mint new
//    rate-limit buckets.
//  * Input is length/charset validated.
//  * Shares ONE rate-limit bucket per student with student_login / portal / leave
//    (the database normalises the "photo:" prefix) and adds a per-IP bucket.
//  * Signed URL lifetime reduced from 24 h to 1 h.
//  * Pinned supabase-js version (this function holds the service-role key).

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

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

function clientIp(req: Request) {
  const h = req.headers;
  const direct = h.get("cf-connecting-ip") || h.get("x-real-ip");
  if (direct) return direct.trim();
  const xff = (h.get("x-forwarded-for") || "").split(",").map((s) => s.trim()).filter(Boolean);
  return xff.length ? xff[xff.length - 1] : "unknown";
}

const escapeLike = (v: string) => v.replace(/[\\%_]/g, (c) => "\\" + c);

// Admission numbers: letters, digits and a few separators only.
const ENROLL_RE = /^[A-Za-z0-9._\-\/ ]{1,40}$/;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ success: false }, 405);

  try {
    const b = await req.json().catch(() => ({}));
    const e = String(b?.enroll_no ?? "").trim();
    const d = String(b?.dob_password ?? "").trim();
    const token = String(b?.session_token ?? "").trim();

    if (!ENROLL_RE.test(e) || (token ? !/^[a-f0-9]{64}$/i.test(token) : !/^[0-9]{8}$/.test(d))) {
      return json({ success: false }, 400);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) return json({ success: false }, 503);

    const sb = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
    });

    const key = "photo:" + e.toUpperCase();

    // 1) per-IP bucket (generous: a whole school can share one Wi-Fi address)
    const ipRate = await sb.rpc("consume_student_login_attempt", {
      p_login_key: "ip:" + clientIp(req),
      p_max_attempts: 300,
      p_window_seconds: 600,
    });
    if (ipRate.error) {
      console.error("student photo ip rate-limit failed:", ipRate.error.message);
      return json({ success: false }, 503);
    }
    if (ipRate.data?.allowed !== true) {
      return json({ success: false, code: "RATE_LIMIT", retry_after_seconds: Number(ipRate.data?.retry_after_seconds || 600) }, 429);
    }

    // 2) per-student bucket (shared with the login RPCs)
    const rate = await sb.rpc("consume_student_login_attempt", {
      p_login_key: key,
      p_max_attempts: 6,
      p_window_seconds: 600,
    });
    if (rate.error) {
      console.error("student photo rate-limit check failed:", rate.error.message);
      return json({ success: false }, 503);
    }
    if (rate.data?.allowed !== true) {
      return json({ success: false, code: "RATE_LIMIT", retry_after_seconds: Number(rate.data?.retry_after_seconds || 600) }, 429);
    }

    let studentRecord: { id: string; enroll_no: string; dob?: string; status: string; photo_path: string | null } | null = null;
    if (token) {
      // Server-side validation checks the hash, expiry, revocation, and active roster status.
      const checked = await sb.rpc("student_session_student_id", { p_token: token });
      if (checked.error || !checked.data) return json({ success: false, code: "STUDENT_SESSION_EXPIRED" }, 401);
      const { data: rows, error } = await sb
        .from("student_roster")
        .select("id,enroll_no,dob,status,photo_path")
        .eq("id", checked.data)
        .eq("school_code", "ashiana")
        .ilike("enroll_no", escapeLike(e))
        .limit(2);
      if (error || !rows || rows.length !== 1) return json({ success: false }, 401);
      studentRecord = rows[0];
    } else {
      const day = +d.slice(0, 2);
      const month = +d.slice(2, 4);
      const year = +d.slice(4, 8);
      const dt = new Date(Date.UTC(year, month - 1, day));
      if (dt.getUTCFullYear() !== year || dt.getUTCMonth() !== month - 1 || dt.getUTCDate() !== day) {
        return json({ success: false }, 401);
      }
      const iso = year + "-" + String(month).padStart(2, "0") + "-" + String(day).padStart(2, "0");
      // Legacy callers remain supported; new Student app requests use the session token.
      const { data: rows, error } = await sb
        .from("student_roster")
        .select("id,enroll_no,dob,status,photo_path")
        .eq("school_code", "ashiana")
        .ilike("enroll_no", escapeLike(e))
        .eq("status", "ACTIVE")
        .eq("dob", iso)
        .limit(2);
      if (error || !rows || rows.length !== 1) return json({ success: false }, 401);
      studentRecord = rows[0];
    }
    const s = studentRecord;

    await sb.rpc("clear_student_login_attempt", { p_login_key: key });

    if (!s.photo_path) return json({ success: true, photo_url: "" });

    const q = await sb.storage.from("student-photos").createSignedUrl(s.photo_path, 3600);
    if (q.error || !q.data?.signedUrl) return json({ success: false, photo_url: "" }, 404);

    return json({ success: true, photo_url: q.data.signedUrl });
  } catch (err) {
    console.error("student-photo-url error:", err instanceof Error ? err.message : String(err));
    return json({ success: false }, 500);
  }
});
