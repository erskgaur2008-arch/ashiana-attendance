// verify-attendance — staff login bridge, PIN change, QR attendance.
//
// SECURITY MODEL (changed):
//  * Staff Supabase Auth passwords are RANDOM and never derived from the PIN.
//    The PIN is verified server-side only (rate limited per staff + per IP),
//    then a session is minted with admin.generateLink + verifyOtp (no password).
//  * No LIKE/ILIKE with user input (wildcards could bypass rate limits).
//  * All credential failures return the same code ("INVALID_PIN") so the
//    endpoint cannot be used to enumerate staff or admin accounts.
//  * Database error text is never returned to the browser.
//
// This function must be deployed with verify_jwt = false (login has no JWT yet);
// the "attendance" and "change_pin" actions validate the JWT themselves.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

// ---------- limits ----------
const PER_STAFF_MAX = 5;        // five failed attempts trigger a 15-minute lockout...
const PER_STAFF_WINDOW = 900;   // ...per 15 minutes
const PER_IP_MAX = 60;          // all login/PIN attempts from one IP...
const PER_IP_WINDOW = 600;      // ...per 10 minutes (school Wi-Fi shares one IP)

// ---------- helpers ----------
async function sha256Hex(value: string) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

function clientIp(req: Request) {
  const h = req.headers;
  const direct = h.get("cf-connecting-ip") || h.get("x-real-ip");
  if (direct) return direct.trim();
  const xff = (h.get("x-forwarded-for") || "").split(",").map((s) => s.trim()).filter(Boolean);
  // The LAST entry is added by the platform; earlier entries are client-supplied.
  return xff.length ? xff[xff.length - 1] : "unknown";
}

// Escape LIKE wildcards so ILIKE behaves as a case-insensitive EXACT match.
const escapeLike = (v: string) => v.replace(/[\\%_]/g, (c) => "\\" + c);

// Random password for Auth accounts. Supabase Auth (bcrypt) rejects passwords longer
// than 72 characters and many projects require lower+upper+digit+symbol, so this is
// 52 chars and always contains all four character types. Nobody ever types it.
const randomSecret = () => {
  const lower = crypto.randomUUID().replace(/-/g, "");
  const upper = crypto.randomUUID().replace(/-/g, "").toUpperCase().slice(0, 16);
  return `Aa1!${lower}${upper}`;
};

function isExpired(validThru?: string | null) {
  if (!validThru) return false;
  const today = new Date().toISOString().slice(0, 10);
  return new Date(validThru + "T00:00:00Z") < new Date(today + "T00:00:00Z");
}

type AdminClient = any;

async function consume(admin: AdminClient, key: string, max: number, windowSeconds: number) {
  const { data, error } = await admin.rpc("consume_staff_login_attempt", {
    p_login_key: await sha256Hex(key),
    p_max_attempts: max,
    p_window_seconds: windowSeconds,
  });
  if (error) throw error;
  return data as { allowed?: boolean; retry_after_seconds?: number } | null;
}

async function clear(admin: AdminClient, key: string) {
  await admin.rpc("clear_staff_login_attempt", { p_login_key: await sha256Hex(key) });
}

const rateLimited = (r: { retry_after_seconds?: number } | null) =>
  json({ error: "RATE_LIMIT", retry_after_seconds: r?.retry_after_seconds || 600 }, 429);

const STAFF_COLUMNS = "id,emp_id,name,department,role,email,status,valid_thru,phone,address";

async function findStaffByEmail(admin: AdminClient, email: string) {
  const { data, error } = await admin
    .from("staff")
    .select(STAFF_COLUMNS)
    .ilike("email", escapeLike(email))
    .eq("status", "ACTIVE")
    .limit(2);
  if (error) throw error;
  return data && data.length === 1 ? data[0] : null; // ambiguous => treat as not found
}

async function requireUser(req: Request, admin: AdminClient) {
  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7).trim() : "";
  if (!token) return null;
  const { data, error } = await admin.auth.getUser(token);
  const email = data?.user?.email?.trim().toLowerCase();
  if (error || !email) return null;
  return { token, email };
}

// Writes a staff PIN with the service role, then confirms the NEW PIN verifies.
// Tries the internal function first, then the public wrapper.
async function setPinServerSide(admin: AdminClient, staffId: string, pin: string) {
  for (const fn of ["set_staff_pin_internal", "set_staff_pin"]) {
    const { data, error } = await admin.rpc(fn, { p_staff_id: staffId, p_pin: pin });
    if (error) {
      console.error(`change_pin: ${fn} failed:`, error.message);
      continue;
    }
    if (data === false) {
      console.error(`change_pin: ${fn} returned false`);
      continue;
    }
    const { data: ok, error: verifyError } = await admin.rpc("verify_staff_pin_internal", { p_staff_id: staffId, p_pin: pin });
    if (!verifyError && ok === true) return true;
    console.error(`change_pin: ${fn} ran but the new PIN does not verify`);
  }
  return false;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !serviceRoleKey || !anonKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 500);

  const authOpts = { auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false } };
  const admin = createClient(supabaseUrl, serviceRoleKey, authOpts);
  const ip = clientIp(req);

  try {
    const body = await req.json().catch(() => ({}));
    const action = String(body?.action || "attendance");

    // =====================================================================
    // STAFF LOGIN  (login id = employee id or email, + 4 digit PIN)
    // =====================================================================
    if (action === "staff_login") {
      const loginId = String(body?.login_id || "").trim().slice(0, 120);
      const pin = String(body?.pin || "").trim();
      if (!loginId || !/^\d{4}$/.test(pin)) return json({ error: "STAFF_LOGIN_ID_AND_4_DIGIT_PIN_REQUIRED" }, 400);

      // 1) per-IP limit first (cheap, before any lookup)
      const ipLimit = await consume(admin, `staff-ip:${ip}`, PER_IP_MAX, PER_IP_WINDOW);
      if (ipLimit?.allowed === false) return rateLimited(ipLimit);

      // 2) exact-match lookup (NO wildcards)
      const normalized = loginId.toLowerCase();
      let staff: Record<string, any> | null = null;
      if (normalized.includes("@")) {
        staff = await findStaffByEmail(admin, normalized);
      } else {
        const { data, error } = await admin
          .from("staff")
          .select(STAFF_COLUMNS)
          .eq("emp_id", loginId.toUpperCase())
          .eq("status", "ACTIVE")
          .maybeSingle();
        if (error) throw error;
        staff = data;
      }

      // 3) per-identity limit: keyed on the real staff id when it exists
      //    (so emp-id and email logins share ONE bucket), else on the typed id.
      const identityKey = staff ? `staff:${staff.id}` : `unknown:${normalized}`;
      const idLimit = await consume(admin, identityKey, PER_STAFF_MAX, PER_STAFF_WINDOW);
      if (idLimit?.allowed === false) return rateLimited(idLimit);

      // 4) verify PIN. Every failure below returns the SAME response.
      const staffEmail = String(staff?.email || "").trim().toLowerCase();
      let pinOk = false;
      if (staff && staffEmail) {
        const { data, error } = await admin.rpc("verify_staff_pin_internal", { p_staff_id: staff.id, p_pin: pin });
        if (error) throw error;
        pinOk = data === true;
      }
      if (!pinOk) return json({ error: "INVALID_PIN" }, 401);

      // Admin accounts must use the separate admin login (same generic reply).
      const { data: adminRow } = await admin
        .from("admin_users")
        .select("email")
        .eq("email", staffEmail)
        .eq("active", true)
        .maybeSingle();
      if (adminRow) return json({ error: "INVALID_PIN" }, 401);

      if (isExpired(staff!.valid_thru)) return json({ error: "ID_CARD_EXPIRED", valid_thru: staff!.valid_thru }, 403);

      // 5) make sure an Auth user exists (random password, never PIN-derived)
      const metadata = {
        staff_id: staff!.id,
        emp_id: staff!.emp_id,
        name: staff!.name,
        account_type: "staff",
      };
      const { data: existingId, error: lookupError } = await admin.rpc("get_auth_user_id_by_email", { p_email: staffEmail });
      if (lookupError) throw lookupError;

      let userId: string | null = existingId || null;
      if (!userId) {
        const { data: created, error: createError } = await admin.auth.admin.createUser({
          email: staffEmail,
          password: randomSecret(),
          email_confirm: true,
          user_metadata: metadata,
        });
        if (createError) {
          console.error("staff login: createUser failed:", createError.message);
          return json({ error: "STAFF_AUTH_ACCOUNT_CREATE_FAILED" }, 500);
        }
        userId = created.user?.id || null;
      }
      if (!userId) return json({ error: "STAFF_AUTH_ACCOUNT_MISSING" }, 500);

      // Rotate the Auth password to a fresh random value on every login and
      // sync metadata. Anything that ever set a guessable password is undone.
      const { error: syncError } = await admin.auth.admin.updateUserById(userId, {
        password: randomSecret(),
        user_metadata: metadata,
      });
      if (syncError) {
        console.error("staff login: Auth sync failed:", syncError.message);
        return json({ error: "STAFF_AUTH_PASSWORD_SYNC_FAILED" }, 500);
      }

      // 6) mint a session WITHOUT any password
      const { data: link, error: linkError } = await admin.auth.admin.generateLink({
        type: "magiclink",
        email: staffEmail,
      });
      const tokenHash = link?.properties?.hashed_token;
      if (linkError || !tokenHash) {
        console.error("staff login: generateLink failed:", linkError?.message || "no token");
        return json({ error: "STAFF_AUTH_SESSION_CREATE_FAILED" }, 500);
      }
      const anon = createClient(supabaseUrl, anonKey, authOpts);
      const { data: verified, error: verifyError } = await anon.auth.verifyOtp({
        type: "email",
        token_hash: tokenHash,
      });
      const s = verified?.session;
      if (verifyError || !s?.access_token || !s?.refresh_token) {
        console.error("staff login: verifyOtp failed:", verifyError?.message || "no session");
        return json({ error: "STAFF_AUTH_SESSION_CREATE_FAILED" }, 500);
      }

      await clear(admin, identityKey);

      // Log only a successful PIN login after a valid session has been minted.
      // Never store the PIN, auth tokens, or other credentials in the monitor.
      const staffIdentifier = String(staff!.emp_id || "").trim().toUpperCase();
      if (staffIdentifier) {
        const { error: activityError } = await admin.from("student_activity_monitor").insert({
          school_code: "ashiana", role: "staff", user_identifier: staffIdentifier,
          user_name: String(staff!.name || "").trim() || null, enroll_no: staffIdentifier,
          class_name: null, section: null, platform: "unknown",
          event_type: "login_success", status: "success"
        });
        if (activityError) console.error("Staff login monitor insert failed:", activityError.message);
      }

      return json({
        success: true,
        session: {
          access_token: s.access_token,
          refresh_token: s.refresh_token,
          expires_in: s.expires_in,
          expires_at: s.expires_at,
          token_type: s.token_type || "bearer",
          user: s.user || null,
        },
        staff: {
          id: staff!.id,
          emp_id: staff!.emp_id,
          name: staff!.name,
          department: staff!.department,
          role: staff!.role,
          email: staffEmail,
          status: staff!.status,
          valid_thru: staff!.valid_thru,
          phone: staff!.phone,
          address: staff!.address,
        },
      });
    }

    // =====================================================================
    // CHANGE PIN (signed-in staff changes their own PIN)
    // The current PIN is verified here (server side, rate limited).
    // The new PIN is written server-side after the caller and current PIN are verified.
    // =====================================================================
    if (action === "change_pin") {
      const user = await requireUser(req, admin);
      if (!user) return json({ error: "AUTHENTICATION_REQUIRED" }, 401);

      const current = String(body?.current_pin || "").trim();
      const next = String(body?.new_pin || "").trim();
      if (!/^\d{4}$/.test(current) || !/^\d{4}$/.test(next)) return json({ error: "PIN_MUST_BE_4_DIGITS" }, 400);

      const ipLimit = await consume(admin, `staff-ip:${ip}`, PER_IP_MAX, PER_IP_WINDOW);
      if (ipLimit?.allowed === false) return rateLimited(ipLimit);

      const staff = await findStaffByEmail(admin, user.email);
      if (!staff) return json({ error: "STAFF_PROFILE_NOT_LINKED" }, 403);

      const key = `staff:${staff.id}`;
      const idLimit = await consume(admin, key, PER_STAFF_MAX, PER_STAFF_WINDOW);
      if (idLimit?.allowed === false) return rateLimited(idLimit);

      const { data: ok, error: pinError } = await admin.rpc("verify_staff_pin_internal", { p_staff_id: staff.id, p_pin: current });
      if (pinError) throw pinError;
      if (ok !== true) return json({ error: "INVALID_PIN" }, 401);

      // Authorization is already done above: the caller's JWT was validated, it maps
      // to exactly one staff row, and the CURRENT PIN was verified. So the PIN is
      // written server-side with the service role (browser roles may not run the
      // internal PIN functions).
      const saved = await setPinServerSide(admin, staff.id, next);
      if (!saved) return json({ error: "PIN_UPDATE_FAILED" }, 400);

      await clear(admin, key);
      return json({ success: true });
    }

    // =====================================================================
    // ATTENDANCE (QR + PIN) — requires a real staff JWT
    // =====================================================================
    if (action !== "attendance") return json({ error: "UNKNOWN_ACTION" }, 400);

    const user = await requireUser(req, admin);
    if (!user) return json({ error: "AUTHENTICATION_REQUIRED" }, 401);

    const qrToken = String(body?.qr_token || "").trim();
    const pin = String(body?.pin || "").trim();
    const passkeyToken = String(body?.passkey_verification_token || "").trim();
    const hasPin = /^\d{4}$/.test(pin);
    if ((!hasPin && passkeyToken.length < 40) || qrToken.length < 20 || qrToken.length > 100) {
      return json({ error: "QR_TOKEN_AND_PIN_OR_PASSKEY_REQUIRED" }, 400);
    }

    const ipLimit = await consume(admin, `staff-ip:${ip}`, PER_IP_MAX, PER_IP_WINDOW);
    if (ipLimit?.allowed === false) return rateLimited(ipLimit);

    const staff = await findStaffByEmail(admin, user.email);
    if (!staff) return json({ error: "STAFF_PROFILE_NOT_LINKED" }, 403);
    if (isExpired(staff.valid_thru)) return json({ error: "ID_CARD_EXPIRED", valid_thru: staff.valid_thru }, 403);

    // PIN guessing protection for the attendance screen too
    const key = `staff:${staff.id}`;
    const idLimit = await consume(admin, key, PER_STAFF_MAX, PER_STAFF_WINDOW);
    if (idLimit?.allowed === false) return rateLimited(idLimit);

    if (passkeyToken) {
      const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(passkeyToken)));
      const tokenHash = Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
      const { data: passkeyOk, error: passkeyError } = await admin.rpc("consume_staff_webauthn_attendance_token", {
        p_token_hash: tokenHash,
        p_staff_id: String(staff.id),
      });
      if (passkeyError) throw passkeyError;
      if (passkeyOk !== true) return json({ error: "PASSKEY_VERIFICATION_REQUIRED_OR_EXPIRED" }, 401);
    } else {
      const { data: pinOk, error: pinError } = await admin.rpc("verify_staff_pin_internal", { p_staff_id: staff.id, p_pin: pin });
      if (pinError) throw pinError;
      if (pinOk !== true) return json({ error: "INVALID_PIN" }, 401);
      await clear(admin, key);
    }

    // Server-side geofence enforcement for Ashiana Public School staff attendance.
    // GPS data is validated for this request and is not persisted.
    const location = body?.location;
    const lat = Number(location?.latitude);
    const lon = Number(location?.longitude);
    const accuracy = Number(location?.accuracy_m);
    const capturedAt = Number(location?.timestamp);
    if (
      !Number.isFinite(lat) || lat < -90 || lat > 90 ||
      !Number.isFinite(lon) || lon < -180 || lon > 180 ||
      !Number.isFinite(accuracy) || !Number.isFinite(capturedAt)
    ) {
      return json({ error: "GEOFENCE_LOCATION_REQUIRED", message: "Precise location is required to mark staff attendance. Enable location and try again." }, 403);
    }
    if (accuracy <= 0 || accuracy > 25) {
      return json({ error: "GEOFENCE_ACCURACY_TOO_LOW", message: "GPS accuracy must be 25 metres or better. Move outdoors, enable precise location, and try again." }, 403);
    }
    const locationAge = Date.now() - capturedAt;
    if (locationAge < -15000 || locationAge > 120000) {
      return json({ error: "GEOFENCE_LOCATION_STALE", message: "Location is out of date. Refresh your location and try again." }, 403);
    }
    const toRad = (value: number) => value * Math.PI / 180;
    const schoolLat = 30.7044541;
    const schoolLon = 76.7675926;
    const dLat = toRad(lat - schoolLat);
    const dLon = toRad(lon - schoolLon);
    const h = Math.sin(dLat / 2) ** 2 +
      Math.cos(toRad(schoolLat)) * Math.cos(toRad(lat)) * Math.sin(dLon / 2) ** 2;
    const distanceMeters = 6371000 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
    if (distanceMeters > 50) {
      return json({ error: "GEOFENCE_OUTSIDE", message: "You are outside the 50-metre school attendance zone. Attendance has not been marked.", distance_m: Math.round(distanceMeters), radius_m: 50, accuracy_m: Math.round(accuracy) }, 403);
    }

    const now = new Date();
    const { data: qr, error: qrError } = await admin
      .from("attendance_qr_sessions")
      .select("id,token,attendance_date,expires_at,active")
      .eq("token", qrToken)
      .eq("active", true)
      .maybeSingle();
    if (qrError || !qr || new Date(qr.expires_at) <= now) return json({ error: "INVALID_OR_EXPIRED_QR" }, 400);

    const today = new Intl.DateTimeFormat("en-CA", {
      timeZone: "Asia/Kolkata",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(now);
    if (qr.attendance_date !== today) return json({ error: "QR_DATE_MISMATCH" }, 400);

    const { data: latest } = await admin
      .from("attendance_punches")
      .select("id,type,timestamp,created_at")
      .eq("staff_id", staff.id)
      .eq("attendance_date", today)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (latest && now.getTime() - new Date(latest.created_at).getTime() < 30000) {
      return json({ error: "DUPLICATE_SCAN_WAIT_30_SECONDS" }, 409);
    }

    const type = latest?.type === "IN" ? "OUT" : "IN";
    const timestamp = new Intl.DateTimeFormat("en-GB", {
      timeZone: "Asia/Kolkata",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    }).format(now);

    const { data: punch, error: insertError } = await admin.rpc("record_attendance_punch_service", {
      p_staff_id: staff.id,
      p_attendance_date: today,
      p_type: type,
      p_timestamp: timestamp,
      p_method: "QR_PIN",
    });

    if (insertError) {
      const msg = String(insertError.message || "");
      console.error("attendance RPC failed:", msg);
      if (msg.includes("DUPLICATE_SCAN_WAIT_30_SECONDS")) return json({ error: "DUPLICATE_SCAN_WAIT_30_SECONDS" }, 409);
      if (msg.includes("PUNCH_SEQUENCE_CONFLICT")) return json({ error: "PUNCH_SEQUENCE_CONFLICT" }, 409);
      return json({ error: "ATTENDANCE_SAVE_FAILED" }, 500); // no DB detail to the browser
    }

    return json({
      success: true,
      message: type === "IN" ? "Attendance IN marked successfully" : "Attendance OUT marked successfully",
      punch,
    });
  } catch (error) {
    console.error("verify-attendance error:", error instanceof Error ? error.message : String(error));
    return json({ error: "SERVER_ERROR" }, 500);
  }
});