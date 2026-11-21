import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const BASE_HEADERS = {
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};
const ALLOWED_ORIGINS = new Set([
  "https://erskgaur2008-arch.github.io",
  "https://localhost",
  "http://localhost",
  "capacitor://localhost",
]);

function reply(body: unknown, status = 200, headers: Record<string, string> = BASE_HEADERS) {
  return new Response(JSON.stringify(body), { status, headers });
}

Deno.serve(async (request: Request) => {
  const origin = request.headers.get("Origin");
  const headers = { ...BASE_HEADERS };
  if (origin && ALLOWED_ORIGINS.has(origin)) headers["Access-Control-Allow-Origin"] = origin;

  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (request.method !== "POST") return reply({ success: false, error: "Method not allowed" }, 405, headers);

  try {
    const body = await request.json().catch(() => ({}));
    const token = String(body?.student_session_token || "");
    if (!/^[a-f0-9]{64}$/i.test(token)) {
      return reply({ success: false, code: "STUDENT_SESSION_EXPIRED" }, 401, headers);
    }

    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) return reply({ success: false, error: "Server configuration unavailable" }, 503, headers);

    const admin = createClient(url, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
    });
    const { data: studentId, error: sessionError } = await admin.rpc("student_session_student_id", { p_token: token });
    if (sessionError || !studentId) return reply({ success: false, code: "STUDENT_SESSION_EXPIRED" }, 401, headers);

    const { data: student, error: studentError } = await admin
      .from("student_roster")
      .select("school_code,class_name,section,status")
      .eq("id", studentId)
      .eq("school_code", "ashiana")
      .ilike("status", "active")
      .maybeSingle();
    if (studentError) {
      console.error("student classmates profile lookup failed:", studentError.message);
      return reply({ success: false, error: "Could not load classmates" }, 500, headers);
    }
    if (!student || !String(student.class_name || "").trim() || !String(student.section || "").trim()) {
      return reply({ success: false, code: "STUDENT_CLASS_SECTION_MISSING" }, 403, headers);
    }

    const { data: classmates, error: classmatesError } = await admin
      .from("student_roster")
      .select("student_name,roll_no,photo_path")
      .eq("school_code", student.school_code)
      .eq("class_name", student.class_name)
      .eq("section", student.section)
      .ilike("status", "active")
      .order("roll_no", { ascending: true, nullsFirst: false })
      .order("student_name", { ascending: true })
      .limit(200);
    if (classmatesError) {
      console.error("student classmates profile list failed:", classmatesError.message);
      return reply({ success: false, error: "Could not load classmates" }, 500, headers);
    }

    const paths = [...new Set((classmates || [])
      .map((row) => String(row.photo_path || "").trim())
      .filter(Boolean))];
    const urlsByPath = new Map<string, string>();
    if (paths.length) {
      const { data: signedUrls, error: signingError } = await admin.storage
        .from("student-photos")
        .createSignedUrls(paths, 600);
      if (signingError) {
        console.error("student classmates photo signing failed:", signingError.message);
      } else {
        for (const item of signedUrls || []) {
          if (item.path && item.signedUrl) urlsByPath.set(item.path, item.signedUrl);
        }
      }
    }

    return reply({
      success: true,
      classmates: (classmates || []).map((row) => ({
        student_name: row.student_name,
        roll_no: row.roll_no,
        photo_url: urlsByPath.get(String(row.photo_path || "").trim()) || "",
      })),
    }, 200, headers);
  } catch (error) {
    console.error("student classmates endpoint failed:", error instanceof Error ? error.message : String(error));
    return reply({ success: false, error: "Could not load classmates" }, 500, headers);
  }
});
