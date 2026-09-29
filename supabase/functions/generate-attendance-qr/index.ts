import { withSupabase } from "npm:@supabase/server";

function indiaDate(d: Date) {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Kolkata",
    year: "numeric", month: "2-digit", day: "2-digit"
  }).format(d);
}

function indiaEndOfDayUtc(d: Date) {
  const date = indiaDate(d);
  return new Date(date + "T18:29:59.999Z");
}

Deno.serve(
  withSupabase({ auth: "user" }, async (req, ctx) => {
    const headers = { "Content-Type": "application/json" };
    if (req.method !== "POST") {
      return Response.json({ error: "METHOD_NOT_ALLOWED" }, { status: 405, headers });
    }

    const userId = String(ctx.userClaims?.sub ?? "");
    const email = String(ctx.userClaims?.email ?? "").trim().toLowerCase();
    if (!userId || !email) return Response.json({ error: "AUTHENTICATION_REQUIRED" }, { status: 401, headers });
    const body = await req.json().catch(() => ({}));
    const tenantId = String(body?.tenant_id ?? "").trim();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(tenantId)) {
      return Response.json({ error: "TENANT_CONTEXT_REQUIRED" }, { status: 400, headers });
    }

    // The selected tenant ID is only a selector. The authenticated identity
    // must hold an active SCHOOL_ADMIN membership in that exact tenant.
    const { data: membership, error: membershipError } = await ctx.supabaseAdmin
      .from("tenant_memberships")
      .select("tenant_id,role,active")
      .eq("user_id", userId)
      .eq("tenant_id", tenantId)
      .eq("active", true)
      .eq("role", "SCHOOL_ADMIN")
      .maybeSingle();
    if (membershipError) {
      console.error("Tenant membership lookup failed:", membershipError);
      return Response.json({ error: "TENANT_AUTHORIZATION_FAILED" }, { status: 500, headers });
    }
    if (!membership) {
      return Response.json({ error: "ADMIN_TENANT_MEMBERSHIP_REQUIRED" }, { status: 403, headers });
    }
    const { data: tenant, error: tenantError } = await ctx.supabaseAdmin
      .from("tenants").select("id,slug,status").eq("id", tenantId).eq("status", "active").maybeSingle();
    if (tenantError || !tenant) {
      return Response.json({ error: "ACTIVE_TENANT_REQUIRED" }, { status: 403, headers });
    }
    const { data: admin, error: adminError } = await ctx.supabaseAdmin
      .from("admin_users").select("email,role,active,tenant_id")
      .eq("email", email).eq("tenant_id", tenant.id).eq("active", true).maybeSingle();
    if (adminError) {
      console.error("Admin profile lookup failed:", adminError);
      return Response.json({ error: "ADMIN_AUTHORIZATION_FAILED" }, { status: 500, headers });
    }
    if (!admin) return Response.json({ error: "ADMIN_REQUIRED" }, { status: 403, headers });

    const now = new Date();
    const attendanceDate = indiaDate(now);
    const expiresAt = indiaEndOfDayUtc(now);

    const { data: existing, error: existingError } = await ctx.supabaseAdmin
      .from("attendance_qr_sessions")
      .select("id,token,attendance_date,expires_at,active,tenant_id")
      .eq("tenant_id", tenant.id)
      .eq("attendance_date", attendanceDate)
      .eq("active", true)
      .gt("expires_at", now.toISOString())
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (existingError) {
      console.error("QR lookup failed:", existingError);
      return Response.json({ error: "QR_SESSION_LOOKUP_FAILED" }, { status: 500, headers });
    }

    // Migrate an old 60-second QR automatically. From now on the day's
    // token must remain valid until 11:59:59 PM IST.
    if (existing && new Date(existing.expires_at).getTime() >= expiresAt.getTime() - 5000) {
      return Response.json({
        success: true, existing: true,
        qr: {
          token: existing.token,
          session_id: existing.id,
          attendance_date: existing.attendance_date,
          expires_at: existing.expires_at,
          active: existing.active,
          valid_for_day: true,
          payload: JSON.stringify({ school: tenant.slug, date: existing.attendance_date, token: existing.token })
        }
      }, { status: 200, headers });
    }

    // Deactivate any old/short-lived session for today before creating
    // the permanent-for-today token.
    if (existing?.id) {
      await ctx.supabaseAdmin.from("attendance_qr_sessions").update({ active: false }).eq("id", existing.id).eq("tenant_id", tenant.id);
    }

    const bytes = crypto.getRandomValues(new Uint8Array(32));
    const token = Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("");

    await ctx.supabaseAdmin
      .from("attendance_qr_sessions")
      .update({ active: false })
      .eq("tenant_id", tenant.id)
      .eq("active", true)
      .lt("expires_at", now.toISOString());

    const { data: session, error } = await ctx.supabaseAdmin
      .from("attendance_qr_sessions")
      .insert({
        token,
        tenant_id: tenant.id,
        attendance_date: attendanceDate,
        created_by: email,
        expires_at: expiresAt.toISOString(),
        active: true
      })
      .select("id,attendance_date,expires_at,active")
      .single();

    if (error) {
      console.error("QR session create failed:", error);
      return Response.json({ error: "QR_SESSION_CREATE_FAILED" }, { status: 500, headers });
    }

    return Response.json({
      success: true, existing: false,
      qr: {
        token,
        session_id: session.id,
        attendance_date: session.attendance_date,
        expires_at: session.expires_at,
        active: session.active,
        valid_for_day: true,
        payload: JSON.stringify({ school: tenant.slug, date: session.attendance_date, token })
      }
    }, { status: 201, headers });
  })
);
