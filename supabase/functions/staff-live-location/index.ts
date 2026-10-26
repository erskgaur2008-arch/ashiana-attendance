import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
});
const clean = (v: unknown, max = 120) => String(v ?? "").trim().slice(0, max);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);
  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7).trim() : "";
  if (!token) return json({ error: "AUTHENTICATION_REQUIRED" }, 401);
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  try {
    const { data: authData, error: authError } = await admin.auth.getUser(token);
    const user = authData?.user;
    const email = clean(user?.email, 200).toLowerCase();
    if (authError || !user?.id || !email) return json({ error: "AUTHENTICATION_REQUIRED" }, 401);
    const body = await req.json().catch(() => ({}));
    const action = clean(body?.action, 40);

    const { data: adminRow } = await admin.from("admin_users").select("email")
      .ilike("email", email).eq("active", true).maybeSingle();
    const isAdmin = Boolean(adminRow);

    if (action === "admin-list") {
      if (!isAdmin) return json({ error: "FORBIDDEN" }, 403);
      const { data, error } = await admin.from("staff_live_locations")
        .select("staff_id,sharing_enabled,latitude,longitude,accuracy_m,captured_at,updated_at,staff:staff!inner(id,emp_id,name,department,role,status)")
        .eq("sharing_enabled", true).order("updated_at", { ascending: false }).limit(500);
      if (error) {
        console.error("staff-live-location admin-list failed:", error.message);
        return json({ error: "LOCATION_LIST_FAILED" }, 500);
      }
      const now = Date.now();
      const locations = (data || []).map((row: any) => ({
        employee_id: row.staff?.emp_id || "",
        name: row.staff?.name || "",
        department: row.staff?.department || "",
        role: row.staff?.role || "",
        latitude: row.latitude,
        longitude: row.longitude,
        accuracy_m: row.accuracy_m,
        captured_at: row.captured_at,
        updated_at: row.updated_at,
        status: row.captured_at && now - new Date(row.captured_at).getTime() <= 120000 ? "LIVE" : "STALE",
      }));
      return json({ success: true, locations, server_time: new Date().toISOString() });
    }

    const { data: staff, error: staffError } = await admin.from("staff")
      .select("id,emp_id,name,email,status").ilike("email", email).eq("status", "ACTIVE").limit(2);
    if (staffError || !staff || staff.length !== 1) return json({ error: "STAFF_PROFILE_NOT_LINKED" }, 403);
    const staffId = staff[0].id;

    if (action === "status") {
      const { data, error } = await admin.from("staff_live_locations").select("sharing_enabled,updated_at")
        .eq("staff_id", staffId).maybeSingle();
      if (error) return json({ error: "LOCATION_STATUS_FAILED" }, 500);
      return json({ success: true, sharing_enabled: Boolean(data?.sharing_enabled), updated_at: data?.updated_at || null });
    }
    if (action === "stop") {
      const { error } = await admin.from("staff_live_locations").upsert({
        staff_id: staffId, sharing_enabled: false, latitude: null, longitude: null,
        accuracy_m: null, captured_at: null, updated_at: new Date().toISOString(),
      }, { onConflict: "staff_id" });
      if (error) return json({ error: "LOCATION_STOP_FAILED" }, 500);
      return json({ success: true, sharing_enabled: false });
    }
    if (action === "start") {
      const { error } = await admin.from("staff_live_locations").upsert({
        staff_id: staffId, sharing_enabled: true, latitude: null, longitude: null,
        accuracy_m: null, captured_at: null, updated_at: new Date().toISOString(),
      }, { onConflict: "staff_id" });
      if (error) return json({ error: "LOCATION_START_FAILED" }, 500);
      return json({ success: true, sharing_enabled: true });
    }
    if (action === "update") {
      const { data: sharing, error: sharingError } = await admin.from("staff_live_locations")
        .select("sharing_enabled").eq("staff_id", staffId).maybeSingle();
      if (sharingError) return json({ error: "LOCATION_STATUS_FAILED" }, 500);
      if (!sharing?.sharing_enabled) return json({ error: "LOCATION_SHARING_NOT_ENABLED" }, 403);
      const latitude = Number(body?.latitude);
      const longitude = Number(body?.longitude);
      const accuracy = Number(body?.accuracy_m);
      const capturedMs = Date.parse(String(body?.captured_at || ""));
      if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90 ||
          !Number.isFinite(longitude) || longitude < -180 || longitude > 180 ||
          !Number.isFinite(accuracy) || accuracy <= 0 || accuracy > 1000 ||
          !Number.isFinite(capturedMs) || Math.abs(Date.now() - capturedMs) > 120000) {
        return json({ error: "INVALID_LOCATION" }, 400);
      }
      const { error } = await admin.from("staff_live_locations").update({
        latitude, longitude, accuracy_m: accuracy,
        captured_at: new Date(capturedMs).toISOString(), updated_at: new Date().toISOString(),
      }).eq("staff_id", staffId).eq("sharing_enabled", true);
      if (error) return json({ error: "LOCATION_UPDATE_FAILED" }, 500);
      return json({ success: true, captured_at: new Date(capturedMs).toISOString() });
    }
    return json({ error: "UNKNOWN_ACTION" }, 400);
  } catch (error) {
    console.error("staff-live-location error:", error instanceof Error ? error.message : String(error));
    return json({ error: "SERVER_ERROR" }, 500);
  }
});
