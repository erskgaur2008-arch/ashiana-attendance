import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "https://esm.sh/@supabase/supabase-js@2/cors";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

function authPassword(staffId: string, pin: string) {
  return `EduPunch!$${staffId}!${pin}`;
}

async function sha256Hex(value: string) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
  });

  try {
    const body = await req.json().catch(() => ({}));
    const action = String(body?.action || "attendance");

    // ============================================================
    // STAFF LOGIN BRIDGE
    // Verifies the 4-digit PIN in the staff table, then ensures
    // Supabase Auth has a policy-compliant derived password.
    // ============================================================
    if (action === "staff_login") {
      const loginId = String(body?.login_id || "").trim();
      const schoolCode = String(body?.school_code || "").trim().toLowerCase();
      const pin = String(body?.pin || "").trim();

      if (!loginId || !/^\d{4}$/.test(pin)) {
        return json({ error: "STAFF_LOGIN_ID_AND_4_DIGIT_PIN_REQUIRED" }, 400);
      }

      const normalized = loginId.toLowerCase();
      const loginKey = await sha256Hex(loginId.includes("@") ? normalized : `${schoolCode}:${loginId.toUpperCase()}`);

      const { data: rate, error: rateError } = await adminClient.rpc(
        "consume_staff_login_attempt",
        { p_login_key: loginKey, p_max_attempts: 6, p_window_seconds: 600 }
      );
      if (rateError) throw rateError;
      if (rate?.allowed === false) {
        return json({
          error: "RATE_LIMIT",
          retry_after_seconds: rate.retry_after_seconds || 600,
        }, 429);
      }

      let staff: any = null;
      let tenant: any = null;
      if (loginId.includes("@")) {
        const result = await adminClient.from("staff")
          .select("id,emp_id,name,department,role,email,status,valid_thru,phone,address,tenant_id")
          .ilike("email", normalized).maybeSingle();
        if (result.error) throw result.error;
        staff = result.data;
        if (staff?.tenant_id) {
          const tenantResult = await adminClient.from("tenants").select("id,slug,status")
            .eq("id", staff.tenant_id).eq("status", "active").maybeSingle();
          if (tenantResult.error) throw tenantResult.error;
          tenant = tenantResult.data;
        }
      } else {
        const tenantResult = await adminClient.from("tenants").select("id,slug,status")
          .eq("slug", schoolCode).eq("status", "active").maybeSingle();
        if (tenantResult.error) throw tenantResult.error;
        tenant = tenantResult.data;
        if (tenant) {
          const result = await adminClient.from("staff")
            .select("id,emp_id,name,department,role,email,status,valid_thru,phone,address,tenant_id")
            .eq("tenant_id", tenant.id).eq("emp_id", loginId.toUpperCase()).maybeSingle();
          if (result.error) throw result.error;
          staff = result.data;
        }
      }

      if (!staff || staff.status !== "ACTIVE" || !staff.email) {
        return json({ error: "STAFF_NOT_FOUND" }, 401);
      }

      const staffEmail = staff.email.trim().toLowerCase();

      // Administrator accounts use their separate Auth password.
      const { data: adminRow } = await adminClient
        .from("admin_users")
        .select("email")
        .eq("email", staffEmail)
        .eq("active", true)
        .maybeSingle();
      if (adminRow) {
        return json({ error: "ADMIN_ACCOUNT_USE_ADMIN_LOGIN" }, 403);
      }

      if (!tenant || !staff || staff.tenant_id !== tenant.id) {
        return json({ error: "STAFF_NOT_FOUND" }, 401);
      }

      const { data: pinOk, error: pinError } = await adminClient.rpc(
        "verify_staff_pin_internal",
        { p_staff_id: staff.id, p_pin: pin }
      );
      if (pinError) throw pinError;
      if (pinOk !== true) return json({ error: "INVALID_PIN" }, 401);

      if (staff.valid_thru && new Date(staff.valid_thru + "T00:00:00Z") < new Date(new Date().toISOString().slice(0, 10) + "T00:00:00Z")) {
        return json({ error: "ID_CARD_EXPIRED", valid_thru: staff.valid_thru }, 403);
      }

      const { data: authUserId, error: lookupError } =
        await adminClient.rpc("get_auth_user_id_by_email", { p_email: staffEmail });
      if (lookupError) throw lookupError;

      let userId = authUserId || null;
      if (!userId) {
        const { data: created, error: createError } =
          await adminClient.auth.admin.createUser({
            email: staffEmail,
            password: authPassword(staff.id, pin),
            email_confirm: true,
            user_metadata: {
              staff_id: staff.id,
              emp_id: staff.emp_id,
              name: staff.name,
              account_type: "staff",
            },
          });
        if (createError) {
          console.error("staff login Auth createUser failed:", createError);
          return json({ error: "STAFF_AUTH_ACCOUNT_CREATE_FAILED" }, 500);
        }
        userId = created.user?.id || null;
      }

      if (!userId) return json({ error: "STAFF_AUTH_ACCOUNT_MISSING" }, 500);

      const { error: authUpdateError } =
        await adminClient.auth.admin.updateUserById(userId, {
          password: authPassword(staff.id, pin),
          user_metadata: {
            staff_id: staff.id,
            emp_id: staff.emp_id,
            name: staff.name,
            account_type: "staff",
          },
        });
      if (authUpdateError) {
        console.error("staff login Auth password sync failed:", authUpdateError);
        return json({ error: "STAFF_AUTH_PASSWORD_SYNC_FAILED" }, 500);
      }

      const { data: memberships, error: membershipError } = await adminClient
        .from("tenant_memberships").select("tenant_id,role,active")
        .eq("user_id", userId).eq("active", true);
      if (membershipError) throw membershipError;
      if ((memberships || []).some((m: any) => m.tenant_id !== tenant.id)) {
        return json({ error: "STAFF_TENANT_MEMBERSHIP_CONFLICT" }, 403);
      }
      if (!(memberships || []).some((m: any) => m.tenant_id === tenant.id)) {
        const { error: membershipInsertError } = await adminClient.from("tenant_memberships")
          .upsert({ tenant_id: tenant.id, user_id: userId, role: "STAFF", active: true },
            { onConflict: "tenant_id,user_id" });
        if (membershipInsertError) throw membershipInsertError;
      }

      await adminClient.rpc("clear_staff_login_attempt", { p_login_key: loginKey });

      return json({
        success: true,
        staff: {
          id: staff.id,
          emp_id: staff.emp_id,
          name: staff.name,
          department: staff.department,
          role: staff.role,
          email: staffEmail,
          status: staff.status,
          valid_thru: staff.valid_thru,
          phone: staff.phone,
          address: staff.address,
          tenant_id: tenant.id,
          school_code: tenant.slug,
        },
      });
    }

    // ============================================================
    // ATTENDANCE VERIFICATION
    // This action requires a real Supabase Auth user JWT.
    // The function itself validates the JWT because this function
    // intentionally has verify_jwt=false for the login bridge.
    // ============================================================
    if (action !== "attendance") {
      return json({ error: "UNKNOWN_ACTION" }, 400);
    }

    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
    if (!token) return json({ error: "AUTHENTICATION_REQUIRED" }, 401);

    const { data: userData, error: userError } = await adminClient.auth.getUser(token);
    if (userError || !userData?.user?.email) return json({ error: "INVALID_OR_EXPIRED_SESSION" }, 401);

    const email = userData.user.email.trim().toLowerCase();
    const qrToken = String(body?.qr_token || "").trim();
    const pin = String(body?.pin || "").trim();

    if (!/^\d{4}$/.test(pin) || qrToken.length < 20 || qrToken.length > 100) {
      return json({ error: "QR_TOKEN_AND_4_DIGIT_PIN_REQUIRED" }, 400);
    }

    const { data: staff, error: staffError } = await adminClient
      .from("staff")
      .select("id,emp_id,name,email,status,valid_thru,tenant_id")
      .ilike("email", email)
      .eq("status", "ACTIVE")
      .maybeSingle();

    if (staffError || !staff?.tenant_id) return json({ error: "STAFF_PROFILE_NOT_LINKED" }, 403);
    const { data: membership, error: membershipError } = await adminClient
      .from("tenant_memberships").select("tenant_id")
      .eq("user_id", userData.user.id).eq("tenant_id", staff.tenant_id).eq("active", true).maybeSingle();
    if (membershipError || !membership) return json({ error: "STAFF_TENANT_MEMBERSHIP_REQUIRED" }, 403);

    if (staff.valid_thru && new Date(staff.valid_thru + "T00:00:00Z") < new Date(new Date().toISOString().slice(0, 10) + "T00:00:00Z")) {
      return json({ error: "ID_CARD_EXPIRED", valid_thru: staff.valid_thru }, 403);
    }

    const { data: pinOk, error: pinError } = await adminClient.rpc(
      "verify_staff_pin_internal",
      { p_staff_id: staff.id, p_pin: pin }
    );
    if (pinError || pinOk !== true) return json({ error: "INVALID_PIN" }, 401);

    const now = new Date();
    const { data: qr, error: qrError } = await adminClient
      .from("attendance_qr_sessions")
      .select("id,token,attendance_date,expires_at,active,tenant_id")
      .eq("token", qrToken)
      .eq("tenant_id", staff.tenant_id)
      .eq("active", true)
      .maybeSingle();

    if (qrError || !qr || new Date(qr.expires_at) <= now) {
      return json({ error: "INVALID_OR_EXPIRED_QR" }, 400);
    }

    const today = new Intl.DateTimeFormat("en-CA", {
      timeZone: "Asia/Kolkata",
      year: "numeric", month: "2-digit", day: "2-digit"
    }).format(now);

    if (qr.attendance_date !== today) return json({ error: "QR_DATE_MISMATCH" }, 400);

    const { data: latest } = await adminClient
      .from("attendance_punches")
      .select("id,type,timestamp,created_at")
      .eq("staff_id", staff.id)
      .eq("tenant_id", staff.tenant_id)
      .eq("attendance_date", today)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (latest && (now.getTime() - new Date(latest.created_at).getTime()) < 30000) {
      return json({ error: "DUPLICATE_SCAN_WAIT_30_SECONDS" }, 409);
    }

    const type = latest?.type === "IN" ? "OUT" : "IN";
    const timestamp = new Intl.DateTimeFormat("en-GB", {
      timeZone: "Asia/Kolkata",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false
    }).format(now);

    const { data: punch, error: insertError } = await adminClient.rpc(
      "record_attendance_punch_service",
      {
        p_staff_id: staff.id,
        p_attendance_date: today,
        p_type: type,
        p_timestamp: timestamp,
        p_method: "QR_PIN"
      }
    );

    if (insertError) {
      console.error("attendance RPC failed:", insertError);
      return json({
        error: "ATTENDANCE_SAVE_FAILED",
        detail: insertError.message || "Attendance record could not be saved."
      }, 500);
    }

    return json({
      success: true,
      message: type === "IN" ? "Attendance IN marked successfully" : "Attendance OUT marked successfully",
      punch
    });
  } catch (error) {
    console.error("verify-attendance error:", error);
    return json({ error: error instanceof Error ? error.message : "Attendance verification failed." }, 500);
  }
});
