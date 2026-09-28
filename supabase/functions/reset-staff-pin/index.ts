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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ error: "Server authentication configuration is missing." }, 500);
  }

  const body = await req.json().catch(() => ({}));
  const mode = String(body?.mode || "reset_pin");

  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
  if (!token) return json({ error: "Authentication required." }, 401);

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
  });

  try {
    // -------------------------
    // Self-service staff PIN reset
    // The browser first verifies the staff's registered email with a
    // Supabase Auth OTP. This branch then accepts only that authenticated
    // staff user's own account and updates the PIN + derived Auth password.
    // -------------------------
    if (mode === "self_reset_pin") {
      const { data: userData, error: userError } = await adminClient.auth.getUser(token);
      if (userError || !userData?.user?.email) {
        return json({ error: "INVALID_OR_EXPIRED_OTP_SESSION" }, 401);
      }

      const email = userData.user.email.trim().toLowerCase();
      const pin = String(body?.pin || "").trim();
      if (!/^\d{4}$/.test(pin)) return json({ error: "PIN must be exactly 4 digits." }, 400);

      const { data: staff, error: staffError } = await adminClient
        .from("staff")
        .select("id,emp_id,name,email,status,tenant_id")
        .ilike("email", email)
        .maybeSingle();
      if (staffError) throw staffError;
      if (!staff || staff.status !== "ACTIVE" || !staff.tenant_id) return json({ error: "STAFF_NOT_FOUND" }, 404);

      const { data: selfMembership } = await adminClient.from("tenant_memberships")
        .select("tenant_id,role").eq("user_id", userData.user.id)
        .eq("tenant_id", staff.tenant_id).eq("active", true).maybeSingle();
      const { data: selfTenant } = await adminClient.from("tenants").select("id")
        .eq("id", staff.tenant_id).eq("status", "active").maybeSingle();
      if (!selfMembership || selfMembership.role !== "STAFF" || !selfTenant) {
        return json({ error: "STAFF_TENANT_MEMBERSHIP_REQUIRED" }, 403);
      }

      if (staff.email.trim().toLowerCase() !== email) {
        return json({ error: "STAFF_EMAIL_MISMATCH" }, 403);
      }

      const { data: adminRow } = await adminClient
        .from("admin_users")
        .select("email")
        .eq("email", email)
        .eq("active", true)
        .maybeSingle();
      if (adminRow) return json({ error: "ADMIN_ACCOUNT_USE_ADMIN_LOGIN" }, 403);

      // Update Auth first. If the database PIN update subsequently fails, the
      // caller can retry the same PIN to converge both credential stores.
      const { error: authUpdateError } = await adminClient.auth.admin.updateUserById(
        userData.user.id,
        {
          password: authPassword(staff.id, pin),
          user_metadata: {
            staff_id: staff.id,
            emp_id: staff.emp_id,
            name: staff.name,
            account_type: "staff",
          },
        }
      );
      if (authUpdateError) throw authUpdateError;

      const { data: pinSet, error: pinError } = await adminClient.rpc("set_staff_pin_service", {
        p_staff_id: staff.id,
        p_pin: pin,
      });
      if (pinError) {
        console.error("Database PIN update failed after Auth password update:", pinError);
        return json({ error: "PIN_AUTH_SYNC_PENDING", message: "Auth password was updated, but the attendance PIN could not be confirmed. Retry the same PIN to synchronize it." }, 503);
      }
      if (pinSet !== true) {
        return json({ error: "PIN_AUTH_SYNC_PENDING", message: "Auth password was updated, but the attendance PIN could not be confirmed. Retry the same PIN to synchronize it." }, 503);
      }

      return json({
        success: true,
        staff: { id: staff.id, emp_id: staff.emp_id, name: staff.name, email: staff.email },
        message: "Staff 4-digit PIN reset successfully.",
      });
    }

    // Existing create/reset operations require an authorized administrator.
    const { data: adminUserData, error: adminUserError } = await adminClient.auth.getUser(token);
    if (adminUserError || !adminUserData?.user?.email) {
      return json({ error: "Invalid or expired administrator session." }, 401);
    }

    const adminEmail = adminUserData.user.email.trim().toLowerCase();
    const { data: authorizedAdmin, error: authorizedAdminError } = await adminClient
      .from("admin_users")
      .select("email,role,active,tenant_id")
      .eq("email", adminEmail)
      .eq("active", true)
      .maybeSingle();

    if (authorizedAdminError) throw authorizedAdminError;
    if (!authorizedAdmin) return json({ error: "Administrator account is not authorized." }, 403);

    const { data: adminMemberships, error: membershipError } = await adminClient.from("tenant_memberships")
      .select("tenant_id,role").eq("user_id", adminUserData.user.id).eq("active", true);
    if (membershipError) throw membershipError;
    if (!adminMemberships || adminMemberships.length !== 1 || adminMemberships[0].role !== "SCHOOL_ADMIN") {
      return json({ error: "ADMIN_TENANT_MEMBERSHIP_REQUIRED" }, 403);
    }
    const adminTenantId = adminMemberships[0].tenant_id;
    const { data: activeTenant, error: tenantError } = await adminClient.from("tenants")
      .select("id").eq("id", adminTenantId).eq("status", "active").maybeSingle();
    if (tenantError) throw tenantError;
    if (!activeTenant || authorizedAdmin.tenant_id !== adminTenantId) {
      return json({ error: "ADMIN_TENANT_MEMBERSHIP_REQUIRED" }, 403);
    }

    // -------------------------
    // Admin: synchronize a staff login email across public.staff and Auth
    // -------------------------
    if (mode === "update_staff_email") {
      const staffId = String(body?.staff_id || "").trim();
      const newEmail = String(body?.email || "").trim().toLowerCase();
      if (!staffId || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(newEmail)) {
        return json({ error: "Staff ID and valid email are required." }, 400);
      }

      const { data: staff, error: staffError } = await adminClient
        .from("staff")
        .select("id,emp_id,name,email,status,tenant_id")
        .eq("id", staffId).eq("tenant_id", adminTenantId)
        .maybeSingle();
      if (staffError) throw staffError;
      if (!staff || staff.status !== "ACTIVE") return json({ error: "Staff member was not found or is inactive." }, 404);

      const oldEmail = staff.email.trim().toLowerCase();
      if (oldEmail === newEmail) {
        return json({ success: true, changed: false, staff: { id: staff.id, email: staff.email } });
      }

      const { data: duplicate, error: duplicateError } = await adminClient
        .from("staff").select("id").ilike("email", newEmail).neq("id", staffId).maybeSingle();
      if (duplicateError) throw duplicateError;
      if (duplicate) return json({ error: "Staff email already exists in another account." }, 409);

      const { data: authUserId, error: lookupError } =
        await adminClient.rpc("get_auth_user_id_by_email", { p_email: oldEmail });
      if (lookupError) throw lookupError;
      if (!authUserId) return json({ error: "Staff Auth account is missing. Reset the staff PIN first." }, 409);

      // Guard against changing an unrelated Auth account if the email lookup
      // resolves unexpectedly or legacy records have become inconsistent.
      const { data: authUserData, error: authReadError } = await adminClient.auth.admin.getUserById(authUserId);
      if (authReadError) throw authReadError;
      if (!authUserData?.user?.email || authUserData.user.email.trim().toLowerCase() !== oldEmail) {
        return json({ error: "STAFF_AUTH_EMAIL_MISMATCH", message: "The linked Auth account email does not match the staff record. Reconcile the account before changing its email." }, 409);
      }

      const { data: updatedStaff, error: staffUpdateError } = await adminClient
        .from("staff").update({ email: newEmail }).eq("id", staffId).eq("tenant_id", adminTenantId)
        .select("id").maybeSingle();
      if (staffUpdateError) throw staffUpdateError;
      if (!updatedStaff?.id) return json({ error: "STAFF_EMAIL_DB_UPDATE_FAILED", message: "The staff email record was not updated. No Auth email change was attempted." }, 409);

      const { error: authUpdateError } = await adminClient.auth.admin.updateUserById(authUserId, {
        email: newEmail,
        email_confirm: true,
        user_metadata: {
          staff_id: staff.id,
          emp_id: staff.emp_id,
          name: staff.name,
          account_type: "staff"
        }
      });
      if (authUpdateError) {
        const { data: rolledBackStaff, error: rollbackError } = await adminClient.from("staff")
          .update({ email: oldEmail }).eq("id", staffId).eq("tenant_id", adminTenantId)
          .select("id").maybeSingle();
        if (rollbackError || !rolledBackStaff?.id) {
          console.error("Staff email rollback failed after Auth update error:", rollbackError);
          return json({ error: "STAFF_EMAIL_SYNC_PENDING", message: "Auth email update failed and the staff record could not be confirmed restored. Contact the platform administrator to reconcile this account before retrying." }, 503);
        }
        throw authUpdateError;
      }

      return json({ success: true, changed: true, staff: { id: staff.id, email: newEmail } });
    }

    // -------------------------
    // Create a brand-new staff account
    // -------------------------
    if (mode === "create_staff") {
      const staffInput = body?.staff || {};
      const pin = String(body?.pin || "").trim();
      const empId = String(staffInput.emp_id || "").trim().toUpperCase();
      const name = String(staffInput.name || "").trim();
      const department = String(staffInput.department || "").trim();
      const role = String(staffInput.role || "").trim();
      const email = String(staffInput.email || "").trim().toLowerCase();
      const status = String(staffInput.status || "ACTIVE").trim().toUpperCase() === "INACTIVE" ? "INACTIVE" : "ACTIVE";

      if (!/^\d{4}$/.test(pin)) return json({ error: "PIN must be exactly 4 digits." }, 400);
      if (!empId || !name || !email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        return json({ error: "Employee ID, name and valid email are required." }, 400);
      }

      const { data: duplicateEmp, error: empCheckError } = await adminClient
        .from("staff").select("id").eq("tenant_id", adminTenantId).eq("emp_id", empId).maybeSingle();
      if (empCheckError) throw empCheckError;
      if (duplicateEmp) return json({ error: "Employee ID already exists in this school." }, 409);

      const { data: duplicateEmail, error: emailCheckError } = await adminClient
        .from("staff").select("id").ilike("email", email).maybeSingle();
      if (emailCheckError) throw emailCheckError;
      if (duplicateEmail) return json({ error: "Staff email already exists." }, 409);

      const staffId = `usr_${crypto.randomUUID()}`;
      const { data: createdStaff, error: staffCreateError } = await adminClient.rpc(
        "create_staff_with_pin_tenant",
        {
          p_tenant_id: adminTenantId,
          p_id: staffId,
          p_emp_id: empId,
          p_name: name,
          p_department: department,
          p_role: role,
          p_email: email,
          p_status: status,
          p_pin: pin,
          p_phone: String(staffInput.phone || "").trim() || null,
          p_address: String(staffInput.address || "").trim() || null,
          p_valid_thru: staffInput.valid_thru || null,
        }
      );
      if (staffCreateError) {
        if (staffCreateError.code === "23505") return json({ error: "Employee ID or email already exists." }, 409);
        throw staffCreateError;
      }
      if (!createdStaff) throw new Error("Staff record creation returned no record.");

      const { data: createdAuth, error: authCreateError } = await adminClient.auth.admin.createUser({
        email,
        password: authPassword(staffId, pin),
        email_confirm: true,
        user_metadata: { staff_id: staffId, emp_id: empId, name, account_type: "staff" },
      });
      if (authCreateError || !createdAuth.user?.id) {
        const { error: rollbackError } = await adminClient.from("staff")
          .delete().eq("id", staffId).eq("tenant_id", adminTenantId);
        if (rollbackError) console.error("staff row cleanup failed after Auth create error:", rollbackError);
        return json({ error: "Unable to create the staff Auth account." }, 409);
      }

      const { error: membershipInsertError } = await adminClient.from("tenant_memberships").upsert(
        { tenant_id: adminTenantId, user_id: createdAuth.user.id, role: "STAFF", active: status === "ACTIVE" },
        { onConflict: "tenant_id,user_id" }
      );
      if (membershipInsertError) {
        const { error: authDeleteError } = await adminClient.auth.admin.deleteUser(createdAuth.user.id);
        const { error: staffDeleteError } = await adminClient.from("staff")
          .delete().eq("id", staffId).eq("tenant_id", adminTenantId);
        if (authDeleteError) console.error("Auth cleanup failed after membership error:", authDeleteError);
        if (staffDeleteError) console.error("staff cleanup failed after membership error:", staffDeleteError);
        throw membershipInsertError;
      }

      return json({
        success: true,
        accountCreated: true,
        staff: {
          id: createdStaff.id, emp_id: createdStaff.emp_id, name: createdStaff.name,
          department: createdStaff.department, role: createdStaff.role,
          email: createdStaff.email, status: createdStaff.status, tenant_id: adminTenantId,
        },
        auth_user_id: createdAuth.user.id,
        message: "Staff account and 4-digit PIN created successfully.",
      }, 201);
    }

    // Existing staff PIN reset
    // -------------------------
    const staffId = String(body?.staff_id || "").trim();
    const pin = String(body?.pin || "").trim();

    if (!staffId) return json({ error: "Staff member is required." }, 400);
    if (!/^\d{4}$/.test(pin)) return json({ error: "PIN must be exactly 4 digits." }, 400);

    const { data: staff, error: staffError } = await adminClient
      .from("staff")
      .select("id,emp_id,name,email,status,tenant_id")
      .eq("id", staffId).eq("tenant_id", adminTenantId)
      .maybeSingle();

    if (staffError) throw staffError;
    if (!staff || staff.status !== "ACTIVE") {
      return json({ error: "Staff member was not found or is inactive." }, 404);
    }
    if (!staff.email?.trim()) return json({ error: "This staff member has no email address." }, 400);

    const staffEmail = staff.email.trim().toLowerCase();

    // An active administrator must keep the administrator's own Supabase password.
    const { data: isAdmin } = await adminClient
      .from("admin_users")
      .select("email")
      .eq("email", staffEmail)
      .eq("tenant_id", adminTenantId)
      .eq("active", true)
      .maybeSingle();

    if (isAdmin) {
      return json({
        error: "ADMIN_ACCOUNT_PIN_NOT_USED_FOR_AUTH",
        message: "This email is an administrator account. Change the administrator password through Supabase Auth instead of Staff PIN reset."
      }, 409);
    }

    const { data: authUserId, error: lookupError } =
      await adminClient.rpc("get_auth_user_id_by_email", { p_email: staffEmail });
    if (lookupError) throw lookupError;

    let userId = authUserId || null;
    let accountCreated = false;

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
        return json({ error: `Unable to create the staff Auth account: ${createError.message}` }, 409);
      }
      userId = created.user?.id || null;
      accountCreated = true;
    }

    if (!userId) return json({ error: "Staff Auth account could not be located." }, 404);

    // Update Auth first. A subsequent DB failure is explicitly reported so
    // the administrator can retry the same PIN and converge both stores.
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
    if (authUpdateError) throw authUpdateError;

    const { data: pinSet, error: pinError } =
      await adminClient.rpc("set_staff_pin_service", {
        p_staff_id: staff.id,
        p_pin: pin,
      });
    if (pinError || pinSet !== true) {
      console.error("Database PIN update failed after Auth password update:", pinError);
      return json({ error: "PIN_AUTH_SYNC_PENDING", message: "Auth password was updated, but the attendance PIN could not be confirmed. Retry the same PIN to synchronize it." }, 503);
    }

    return json({
      success: true,
      accountCreated,
      staff: { id: staff.id, emp_id: staff.emp_id, name: staff.name, email: staff.email },
      message: "Staff 4-digit PIN reset successfully.",
    });
  } catch (error) {
    console.error("reset-staff-pin error:", error);
    return json({ error: error instanceof Error ? error.message : "PIN reset failed." }, 500);
  }
});
