import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: cors });

// Escape SQL LIKE metacharacters before using ILIKE for exact identity matching.
const escapeLike = (value: string) => value.replace(/[\\%_]/g, (character) => "\\" + character);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "POST required" });
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!url || !anonKey || !serviceKey || !token) return reply(401, { error: "Authentication required" });
  const authClient = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await authClient.auth.getUser(token);
  const user = authData?.user;
  if (authError || !user?.email) return reply(401, { error: "Valid signed-in user required" });
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const email = user.email.toLowerCase();
  const { data: admin, error: adminError } = await db.from("admin_users")
    .select("email,role,active").ilike("email", escapeLike(email)).eq("active", true).maybeSingle();
  if (adminError || !admin || String(admin.role).toUpperCase() !== "ADMIN")
    return reply(403, { error: "Active Admin access required" });
  let input: Record<string, unknown>;
  try { input = await req.json(); } catch { return reply(400, { error: "Valid JSON body required" }); }
  const action = String(input.action || "");
  if (action === "list") {
    const status = typeof input.status === "string" ? input.status : null;
    let query = db.from("attendance_punch_correction_requests").select("*").order("created_at", { ascending: false }).limit(100);
    if (status && ["PENDING", "APPROVED", "REJECTED", "CANCELLED"].includes(status)) query = query.eq("status", status);
    const { data, error } = await query;
    if (error) return reply(500, { error: "Could not load correction requests" });
    return reply(200, { requests: data || [] });
  }
  if (action === "create") {
    const staffId = String(input.staff_id || "").trim();
    const date = String(input.attendance_date || "").trim();
    const evidence = String(input.evidence_reference || "").trim();
    const reason = String(input.reviewer_reason || "").trim();
    const proposed = input.proposed_change;
    if (!staffId || !/^\d{4}-\d{2}-\d{2}$/.test(date) || !evidence || !reason ||
        !proposed || typeof proposed !== "object" || Array.isArray(proposed))
      return reply(400, { error: "Staff, date, evidence, reason and proposed change are required" });
    const { data: staff, error: staffError } = await db.from("staff").select("id,emp_id,name").eq("id", staffId).maybeSingle();
    if (staffError || !staff) return reply(404, { error: "Staff record not found" });
    const { data: existing } = await db.from("attendance_punch_correction_requests")
      .select("id").eq("staff_id", staffId).eq("attendance_date", date).eq("status", "PENDING").limit(1);
    if (existing?.length) return reply(409, { error: "A pending request already exists for this employee and date", request_id: existing[0].id });
    const { data: punches, error: punchError } = await db.from("attendance_punches")
      .select("id,staff_id,emp_id,staff_name,attendance_date,type,timestamp,method,created_at")
      .eq("staff_id", staffId).eq("attendance_date", date).order("created_at", { ascending: true });
    if (punchError) return reply(500, { error: "Could not read original punches" });
    const { data, error } = await db.from("attendance_punch_correction_requests").insert({
      staff_id: staff.id, emp_id: staff.emp_id, staff_name: staff.name, attendance_date: date,
      original_punch_ids: (punches || []).map((p: {id:string}) => p.id),
      original_punch_snapshot: punches || [], proposed_change: proposed,
      evidence_reference: evidence, reviewer_reason: reason, requested_by_email: email
    }).select("*").single();
    if (error) return reply(error.code === "23505" ? 409 : 500, { error: error.code === "23505" ? "A pending correction request already exists for this employee and date" : "Could not create correction request" });
    return reply(201, { request: data, message: "Request recorded. No attendance punch was changed." });
  }
  if (action === "approve" || action === "reject") {
    const id = String(input.request_id || "").trim();
    const note = String(input.review_note || "").trim();
    if (!id || !note) return reply(400, { error: "Request ID and review note are required" });
    const { data: existing } = await db.from("attendance_punch_correction_requests")
      .select("id,status,requested_by_email").eq("id", id).maybeSingle();
    if (!existing) return reply(404, { error: "Correction request not found" });
    if (existing.status !== "PENDING") return reply(409, { error: "Only pending requests can be reviewed" });
    if (String(existing.requested_by_email).toLowerCase() === email)
      return reply(403, { error: "A different Admin must review this request" });
    const status = action === "approve" ? "APPROVED" : "REJECTED";
    const { data, error } = await db.from("attendance_punch_correction_requests")
      .update({ status, reviewed_by_email: email, reviewed_at: new Date().toISOString(), review_note: note, updated_at: new Date().toISOString() })
      .eq("id", id).eq("status", "PENDING").select("*").maybeSingle();
    if (error || !data) return reply(409, { error: "Request changed concurrently or could not be reviewed" });
    return reply(200, { request: data, message: `Request ${status.toLowerCase()}. Original punches remain unchanged.` });
  }
  return reply(400, { error: "Unsupported action" });
});