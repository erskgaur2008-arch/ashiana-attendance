import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import webpush from "npm:web-push@3.6.7";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
};
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers });
const categories = new Set(["school_notice", "leave_status", "homework_timetable", "attendance_update"]);
const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const FCM_TOKEN_URL = "https://oauth2.googleapis.com/token";

// Treat identity fields as literal email addresses, never SQL ILIKE patterns.
const escapeLike = (value: string) => value.replace(/[\\%_]/g, (character) => "\\" + character);

type ServiceAccount = { project_id: string; client_email: string; private_key: string };
type WebPushSubscription = { endpoint: string; keys: { p256dh: string; auth: string } };
type StudentPushRow = {
  id: string;
  platform: "web" | "android";
  endpoint: string | null;
  subscription: Record<string, unknown> | null;
  device_token: string | null;
  class_name: string | null;
  section: string | null;
  enroll_no?: string | null;
};

function base64Url(value: string | Uint8Array) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, Math.min(i + 0x8000, bytes.length)));
  }
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function pemToBytes(pem: string) {
  const clean = pem.replace(/\\n/g, "\n").replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const binary = atob(clean);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

async function getFcmAccessToken(account: ServiceAccount) {
  if (!account.client_email || !account.private_key || !account.project_id) {
    throw new Error("FCM service account configuration is incomplete.");
  }
  const now = Math.floor(Date.now() / 1000);
  const unsigned = base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" })) + "." +
    base64Url(JSON.stringify({ iss: account.client_email, scope: FCM_SCOPE, aud: FCM_TOKEN_URL, iat: now, exp: now + 3600 }));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToBytes(account.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned)));
  const assertion = unsigned + "." + base64Url(signature);
  const response = await fetch(FCM_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok || !result.access_token) {
    throw new Error("Google OAuth token request failed with status " + response.status + ".");
  }
  return String(result.access_token);
}

async function sendFcm(accessToken: string, projectId: string, deviceToken: string, title: string, message: string, category: string) {
  const response = await fetch("https://fcm.googleapis.com/v1/projects/" + encodeURIComponent(projectId) + "/messages:send", {
    method: "POST",
    headers: { Authorization: "Bearer " + accessToken, "Content-Type": "application/json" },
    body: JSON.stringify({
      message: {
        token: deviceToken,
        notification: { title, body: message },
        data: { category, url: "/" },
        android: { priority: "high", notification: { channel_id: "school_updates", sound: "default" } },
      },
    }),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    const detail = String(result?.error?.details?.[0]?.errorCode || result?.error?.status || "");
    return { ok: false, status: response.status, detail };
  }
  return { ok: true, status: response.status, detail: "" };
}

function normalizeServiceAccount() {
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON") || "";
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as ServiceAccount;
    return parsed?.project_id && parsed?.client_email && parsed?.private_key ? parsed : null;
  } catch {
    return null;
  }
}

async function sendWebPush(row: StudentPushRow, title: string, message: string, category: string, service: ReturnType<typeof createClient>) {
  if (!row.subscription) return false;
  try {
    await webpush.sendNotification(row.subscription as WebPushSubscription, JSON.stringify({
      title, body: message, category, tag: category + ":" + crypto.randomUUID(), url: "/",
    }));
    return true;
  } catch (error) {
    const status = Number((error as { statusCode?: number })?.statusCode || 0);
    if ((status === 404 || status === 410) && row.id) {
      await service.from("student_push_subscriptions").delete().eq("id", row.id);
    }
    return false;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !serviceKey) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 503);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "INVALID_JSON" }, 400); }
  const action = String(body.action || "");
  const vapidPublic = Deno.env.get("VAPID_PUBLIC_KEY") || "";
  const vapidPrivate = Deno.env.get("VAPID_PRIVATE_KEY") || "";
  const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "";
  const webPushConfigured = Boolean(vapidPublic && vapidPrivate && vapidSubject);
  const fcmAccount = normalizeServiceAccount();

  // The VAPID public key is public by design. This action is also needed by
  // RPC-authenticated students who do not have a Supabase Auth session.
  if (action === "config") {
    return json({ vapidPublicKey: vapidPublic, webPushConfigured, androidPushConfigured: Boolean(fcmAccount) });
  }

  const service = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

  // Record successful student login only after validating the revocable session token.
  if (action === "student-login-event") {
    const token = String(body.sessionToken || "");
    if (!/^[a-f0-9]{64}$/i.test(token)) return json({ error: "INVALID_STUDENT_SESSION" }, 401);
    const anonClient = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: bundle, error: bundleError } = await anonClient.rpc("student_portal_bundle_by_session", { p_token: token });
    const student = (bundle?.student || {}) as Record<string, unknown>;
    const enrollNo = String(student.enroll_no || student.admission_no || "").trim().toUpperCase();
    if (bundleError || !bundle || !enrollNo) return json({ error: "INVALID_STUDENT_SESSION" }, 401);
    const platform = String(body.platform || "unknown");
    const { error: logError } = await service.from("student_activity_monitor").insert({
      school_code: "ashiana",
      enroll_no: enrollNo,
      class_name: String(student.class_name || student.class || "").trim() || null,
      section: String(student.section || student.section_name || "").trim() || null,
      platform: ["android", "web"].includes(platform) ? platform : "unknown",
      event_type: "login_success", status: "success"
    });
    if (logError) { console.error("Student login monitor insert failed:", logError.message); return json({ error: "ACTIVITY_LOG_UNAVAILABLE" }, 500); }
    return json({ success: true });
  }

  // Students use the existing admission-number + DOB RPC session rather than
  // Supabase Auth. Validate the credentials through the existing login RPC
  // before associating any device token/subscription with a student.
  if (action === "student-subscribe") {
    const schoolCode = String(body.schoolCode || "").trim().toLowerCase();
    const enrollNo = String(body.admissionNo || "").trim().toUpperCase();
    const dobPassword = String(body.dobPassword || "").replace(/\D/g, "");
    const platform = String(body.platform || "");
    if (schoolCode !== "ashiana" || !enrollNo || !/^\d{8}$/.test(dobPassword)) {
      return json({ error: "INVALID_STUDENT_CREDENTIALS" }, 400);
    }
    if (platform !== "android" && platform !== "web") return json({ error: "INVALID_PLATFORM" }, 400);

    const studentClient = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: login, error: loginError } = await studentClient.rpc("student_login", {
      p_school_code: schoolCode,
      p_enroll_no: enrollNo,
      p_dob_password: dobPassword,
    });
    if (loginError || !login?.success || !login?.student) {
      return json({ error: "STUDENT_AUTHENTICATION_FAILED" }, 401);
    }

    const student = login.student as Record<string, unknown>;
    const verifiedEnrollNo = String(student.enroll_no || enrollNo).trim().toUpperCase();
    const className = String(student.class_name || student.class || "").trim() || null;
    const section = String(student.section || student.section_name || "").trim() || null;
    let subscription: Record<string, unknown> | null = null;
    let endpoint: string | null = null;
    let deviceToken: string | null = null;

    if (platform === "android") {
      deviceToken = String(body.deviceToken || "");
      if (deviceToken.length < 20 || deviceToken.length > 4096) return json({ error: "INVALID_DEVICE_TOKEN" }, 400);
      await service.from("student_push_subscriptions").delete().eq("platform", "android").eq("device_token", deviceToken);
    } else {
      if (!webPushConfigured) return json({ error: "WEB_PUSH_NOT_CONFIGURED" }, 503);
      subscription = body.subscription as Record<string, unknown> | null;
      endpoint = String(subscription?.endpoint || "");
      if (!endpoint.startsWith("https://") || !subscription?.keys || typeof subscription.keys !== "object") {
        return json({ error: "INVALID_SUBSCRIPTION" }, 400);
      }
      await service.from("student_push_subscriptions").delete().eq("platform", "web").eq("endpoint", endpoint);
    }

    const { error: saveError } = await service.from("student_push_subscriptions").insert({
      school_code: schoolCode,
      enroll_no: verifiedEnrollNo,
      class_name: className,
      section,
      platform,
      device_token: deviceToken,
      endpoint,
      subscription,
      updated_at: new Date().toISOString(),
    });
    if (saveError) return json({ error: "STUDENT_SUBSCRIPTION_SAVE_FAILED" }, 500);
    return json({ success: true, platform, androidPushConfigured: Boolean(fcmAccount), webPushConfigured });
  }

  const auth = req.headers.get("Authorization") || "";
  const client = createClient(url, anon, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await client.auth.getUser();
  if (userError || !userData.user) return json({ error: "AUTH_REQUIRED" }, 401);

  if (action === "admin-push-diagnostics") {
    const callerEmail = String(userData.user.email || "").trim().toLowerCase();
    if (!callerEmail) return json({ error: "ADMIN_REQUIRED" }, 403);
    const { data: admins, error: adminError } = await service.from("admin_users")
      .select("email").eq("active", true).ilike("email", escapeLike(callerEmail)).limit(1);
    if (adminError || !admins?.length) return json({ error: "ADMIN_REQUIRED" }, 403);

    const { data: registrations, error: registrationError } = await service
      .from("student_push_subscriptions")
      .select("enroll_no,class_name,section,platform,created_at,updated_at")
      .eq("school_code", "ashiana")
      .order("updated_at", { ascending: false })
      .limit(500);
    if (registrationError) {
      console.error("Admin push diagnostics query failed:", registrationError.message);
      return json({ error: "PUSH_DIAGNOSTICS_UNAVAILABLE" }, 500);
    }
    const { data: activity, error: activityError } = await service.from("student_activity_monitor")
      .select("enroll_no,class_name,section,platform,event_type,status,created_at")
      .eq("school_code", "ashiana").order("created_at", { ascending: false }).limit(10000);
    if (activityError) {
      console.error("Admin user activity query failed:", activityError.message);
      return json({ error: "USER_ACTIVITY_UNAVAILABLE" }, 500);
    }

    const latestByUser = new Map<string, Record<string, unknown>>();
    for (const event of activity || []) {
      // This production table currently records student activity only. Its actual
      // schema has enroll_no but does not have role/user_identifier/user_name.
      const role = "student";
      const identifier = String(event.enroll_no || "").trim().toUpperCase();
      if (!identifier) continue;
      const key = role + ":" + identifier;
      const item = latestByUser.get(key) || {
        role, user_identifier: identifier,
        class_name: event.class_name, section: event.section, platform: event.platform,
        last_login_at: null, last_push_at: null, last_push_status: null, last_push_error: null
      };
      if (event.event_type === "login_success" && !item.last_login_at) item.last_login_at = event.created_at;
      if (role === "student" && event.event_type === "push_delivery" && !item.last_push_at) {
        item.last_push_at = event.created_at; item.last_push_status = event.status; item.last_push_error = null;
      }
      latestByUser.set(key, item);
    }

    // Active account totals come from the authoritative roster, not push registrations.
    const fetchAll = async (table: string, select: string, filters: Array<[string, unknown]>) => {
      const result: Record<string, unknown>[] = [];
      for (let offset = 0; offset < 10000; offset += 1000) {
        let query: any = service.from(table).select(select);
        for (const [column, value] of filters) query = query.eq(column, value);
        const { data, error } = await query.range(offset, offset + 999);
        if (error) throw new Error(table + "_LOOKUP_FAILED");
        const batch = (data || []) as Record<string, unknown>[];
        result.push(...batch);
        if (batch.length < 1000) break;
      }
      return result;
    };

    let studentAccounts: Record<string, unknown>[], staffAccounts: Record<string, unknown>[], adminAccounts: Record<string, unknown>[];
    try {
      studentAccounts = await fetchAll("student_roster", "enroll_no,student_name,class_name,section,status", [["school_code","ashiana"],["status","ACTIVE"]]);
      staffAccounts = await fetchAll("staff", "emp_id,name,department,role,status", [["status","ACTIVE"]]);
      adminAccounts = await fetchAll("admin_users", "email,active", [["active",true]]);
    } catch (error) {
      console.error("Admin active user lookup failed:", String((error as Error)?.message || error));
      return json({ error: "ACTIVE_USERS_UNAVAILABLE" }, 500);
    }

    const activeUsers: Array<Record<string, unknown>> = [];
    const addActiveUser = (user: Record<string, unknown>) => {
      const role = String(user.role || "student").toLowerCase();
      const identifier = String(user.user_identifier || "").trim();
      if (!identifier) return;
      const login = latestByUser.get(role + ":" + identifier.toUpperCase());
      activeUsers.push({ ...user, last_login_at: login?.last_login_at || null });
    };
    for (const row of studentAccounts) {
      const identifier = String(row.enroll_no || "").trim();
      if (identifier) addActiveUser({ role: "student", user_identifier: identifier, name: row.student_name || null,
        context: [row.class_name, row.section].filter(Boolean).join("-") || null, status: row.status });
    }
    for (const row of staffAccounts) {
      const identifier = String(row.emp_id || "").trim();
      if (identifier) addActiveUser({ role: "staff", user_identifier: identifier, name: row.name || null,
        context: row.department || row.role || null, status: row.status });
    }
    for (const row of adminAccounts) {
      const identifier = String(row.email || "").trim();
      if (identifier) addActiveUser({ role: "admin", user_identifier: identifier, name: identifier,
        context: "Administrator", status: "ACTIVE" });
    }
    const activeUserCounts = {
      students: studentAccounts.length, staff: staffAccounts.length, administrators: adminAccounts.length,
      total: studentAccounts.length + staffAccounts.length + adminAccounts.length,
      withRecordedLogin: activeUsers.filter(user => Boolean(user.last_login_at)).length
    };
    return json({ success: true, registrations: registrations || [], activity: Array.from(latestByUser.values()), activeUsers, activeUserCounts });
  }

  if (action === "send-attendance-update") {
    const callerEmail = String(userData.user.email || "").trim().toLowerCase();
    if (!callerEmail) return json({ error: "AUTH_REQUIRED" }, 401);

    const { data: admins, error: adminError } = await service.from("admin_users")
      .select("email").eq("active", true).ilike("email", escapeLike(callerEmail));
    const isAdmin = !adminError && Boolean(admins?.length);
    const { data: staffRows, error: staffError } = isAdmin ? { data: [], error: null } :
      await service.from("staff").select("email").eq("status", "ACTIVE")
        .ilike("email", escapeLike(callerEmail)).limit(1);
    if (!isAdmin && (staffError || !staffRows?.length)) {
      return json({ error: "ACTIVE_STAFF_REQUIRED" }, 403);
    }

    const schoolCode = String(body.schoolCode || "ashiana").trim().toLowerCase();
    const enrollNo = String(body.admissionNo || "").trim().toUpperCase();
    const attendanceDate = String(body.attendanceDate || "");
    const status = String(body.status || "").trim().toUpperCase();
    if (schoolCode !== "ashiana" || !enrollNo ||
        !/^\d{4}-\d{2}-\d{2}$/.test(attendanceDate) ||
        !["PRESENT", "ABSENT", "LEAVE"].includes(status)) {
      return json({ error: "INVALID_ATTENDANCE_NOTIFICATION" }, 400);
    }

    const { data: student, error: studentError } = await service.from("student_roster")
      .select("id,enroll_no,student_name,class_name,section,status")
      .eq("school_code", schoolCode).ilike("enroll_no", escapeLike(enrollNo))
      .eq("status", "ACTIVE").maybeSingle();
    if (studentError || !student) return json({ error: "ACTIVE_STUDENT_NOT_FOUND" }, 404);

    // A push request cannot create an attendance event by itself: require the
    // authoritative attendance row to have been saved by this caller first.
    let attendanceQuery = service.from("student_attendance").select("student_id,status,marked_by")
      .eq("school_code", schoolCode).eq("student_id", student.id)
      .eq("attendance_date", attendanceDate).eq("status", status);
    if (!isAdmin) attendanceQuery = attendanceQuery.eq("marked_by", userData.user.id);
    const { data: savedMark, error: markError } = await attendanceQuery.maybeSingle();
    if (markError || !savedMark) return json({ error: "SAVED_ATTENDANCE_NOT_FOUND" }, 409);

    const title = "Attendance Marked";
    const message = "Your attendance for " + attendanceDate + " has been marked " + status + ".";
    const { data: created, error: notificationError } = await service
      .from("student_attendance_notifications")
      .upsert({
        school_code: schoolCode, student_id: student.id, attendance_date: attendanceDate,
        status, title, message,
      }, { onConflict: "student_id,attendance_date,status", ignoreDuplicates: true })
      .select("id").maybeSingle();
    if (notificationError) {
      console.error("Attendance notification persistence failed:", notificationError.message);
      return json({ error: "ATTENDANCE_NOTIFICATION_SAVE_FAILED" }, 500);
    }
    if (!created) return json({ success: true, duplicate: true, sent: 0 });

    const { data: subscriptions, error: subscriptionError } = await service
      .from("student_push_subscriptions")
      .select("id,platform,endpoint,subscription,device_token,class_name,section")
      .eq("school_code", schoolCode).ilike("enroll_no", escapeLike(String(student.enroll_no || enrollNo)));
    if (subscriptionError) return json({ success: true, inAppSaved: true, pushError: "SUBSCRIPTION_LOOKUP_FAILED" });

    const rows = (subscriptions || []) as StudentPushRow[];
    const webRows = rows.filter((row) => row.platform === "web");
    const androidRows = rows.filter((row) => row.platform === "android");
    if (webPushConfigured && webRows.length) webpush.setVapidDetails(vapidSubject, vapidPublic, vapidPrivate);

    let fcmAccessToken = "";
    if (androidRows.length && fcmAccount) {
      try { fcmAccessToken = await getFcmAccessToken(fcmAccount); }
      catch (error) { console.error("FCM token setup failed:", (error as Error)?.message || "unknown error"); }
    }

    let sentWeb = 0, sentAndroid = 0, failed = 0, skipped = 0;
    const jobs: Array<Promise<void>> = [];
    for (const row of webRows) {
      if (!webPushConfigured) { skipped++; continue; }
      jobs.push(sendWebPush(row, title, message, "attendance_update", service)
        .then((ok) => { if (ok) sentWeb++; else failed++; }));
    }
    for (const row of androidRows) {
      if (!fcmAccessToken || !fcmAccount) { skipped++; continue; }
      jobs.push(sendFcm(fcmAccessToken, fcmAccount.project_id, String(row.device_token || ""), title, message, "attendance_update")
        .then(async (result) => {
          if (result.ok) sentAndroid++;
          else {
            failed++;
            if (result.detail === "UNREGISTERED" || result.status === 404) {
              await service.from("student_push_subscriptions").delete().eq("id", row.id);
            }
          }
        }));
    }
    for (let i = 0; i < jobs.length; i += 20) await Promise.allSettled(jobs.slice(i, i + 20));
    return json({
      success: true, inAppSaved: true, duplicate: false, subscriptionsFound: rows.length,
      sent: sentWeb + sentAndroid, sentWeb, sentAndroid, failed, skipped,
      webPushConfigured, androidPushConfigured: Boolean(fcmAccessToken),
    });
  }

  if (action === "subscribe" && String(body.platform || "") === "android") {
    const token = String(body.deviceToken || "");
    if (token.length < 20 || token.length > 4096) return json({ error: "INVALID_DEVICE_TOKEN" }, 400);
    const { error } = await client.from("push_subscriptions").upsert({
      user_id: userData.user.id, platform: "android", device_token: token,
      endpoint: null, subscription: null, updated_at: new Date().toISOString(),
    }, { onConflict: "user_id,device_token" });
    if (error) return json({ error: "SUBSCRIPTION_SAVE_FAILED" }, 400);
    return json({ success: true, deliveryConfigured: Boolean(fcmAccount), message: fcmAccount ? "Android delivery is configured." : "FCM_SERVICE_ACCOUNT_JSON is required for Android delivery." });
  }

  if (action === "subscribe") {
    if (!webPushConfigured) return json({ error: "WEB_PUSH_NOT_CONFIGURED" }, 503);
    const subscription = body.subscription as Record<string, unknown> | undefined;
    const endpoint = String(subscription?.endpoint || "");
    if (!endpoint.startsWith("https://") || !subscription?.keys || typeof subscription.keys !== "object") return json({ error: "INVALID_SUBSCRIPTION" }, 400);
    const { error } = await client.from("push_subscriptions").upsert({
      user_id: userData.user.id, platform: "web", endpoint, subscription,
      device_token: null, updated_at: new Date().toISOString(),
    }, { onConflict: "user_id,endpoint" });
    if (error) return json({ error: "SUBSCRIPTION_SAVE_FAILED" }, 400);
    return json({ success: true });
  }

  if (action === "unsubscribe") {
    const endpoint = String(body.endpoint || "");
    if (!endpoint.startsWith("https://")) return json({ error: "INVALID_ENDPOINT" }, 400);
    const { error } = await client.from("push_subscriptions").delete().eq("user_id", userData.user.id).eq("platform", "web").eq("endpoint", endpoint);
    if (error) return json({ error: "UNSUBSCRIBE_FAILED" }, 400);
    return json({ success: true });
  }

  if (action === "send-school-notice" || action === "send") {
    const callerEmail = String(userData.user.email || "").trim().toLowerCase();
    if (!callerEmail) return json({ error: "AUTH_REQUIRED" }, 401);
    const { data: admins, error: adminError } = await service.from("admin_users")
      .select("email").eq("active", true).ilike("email", escapeLike(callerEmail));
    const isAdmin = !adminError && Boolean(admins?.length);
    let isActiveStaff = false;
    if (!isAdmin) {
      const { data: staffRows, error: staffError } = await service.from("staff")
        .select("email").eq("status", "ACTIVE").ilike("email", callerEmail).limit(1);
      isActiveStaff = !staffError && Boolean(staffRows?.length);
    }
    if (!isAdmin && (!isActiveStaff || action !== "send-school-notice")) {
      return json({ error: "ADMIN_OR_AUTHORIZED_STAFF_REQUIRED" }, 403);
    }

    const category = String(body.category || (action === "send-school-notice" ? "school_notice" : ""));
    const title = String(body.title || "").trim().slice(0, 120);
    const message = String(body.message || "").trim().slice(0, 500);
    if (!categories.has(category) || !title || !message) return json({ error: "INVALID_NOTIFICATION" }, 400);

    if (action === "send-school-notice") {
      const schoolCode = String(body.schoolCode || "ashiana").trim().toLowerCase();
      const allStudents = body.allStudents === true;
      const targetScopes = Array.isArray(body.targetScopes) ? body.targetScopes.slice(0, 100).map((scope) => ({
        class_name: String((scope as Record<string, unknown>)?.class_name || "").trim(),
        section: String((scope as Record<string, unknown>)?.section || "").trim(),
      })).filter((scope) => scope.class_name && scope.section) : [];
      if (schoolCode !== "ashiana" || (!allStudents && !targetScopes.length)) return json({ error: "INVALID_NOTICE_TARGET" }, 400);
      // Non-admin staff may only notify class/sections for a notice they just
      // published under their own email. School-wide pushes remain admin-only.
      if (!isAdmin) {
        if (allStudents || !targetScopes.length) return json({ error: "STAFF_NOTICE_TARGET_REQUIRED" }, 403);
        const { data: authoredNotices, error: noticeError } = await service.from("student_notices")
          .select("class_name,section,title,body,published_by")
          .eq("school_code", schoolCode).ilike("published_by", escapeLike(callerEmail))
          .eq("title", title).eq("body", message);
        if (noticeError || !authoredNotices?.length) return json({ error: "STAFF_NOTICE_NOT_FOUND" }, 403);
        const permitted = targetScopes.every((scope) => authoredNotices.some((notice) =>
          String(notice.class_name || "").trim() === scope.class_name &&
          String(notice.section || "").trim().toLowerCase() === scope.section.toLowerCase()));
        if (!permitted) return json({ error: "STAFF_NOTICE_TARGET_MISMATCH" }, 403);
      }

      const rows: StudentPushRow[] = [];
      for (let offset = 0; ; offset += 1000) {
        const { data, error } = await service.from("student_push_subscriptions")
          .select("id,platform,endpoint,subscription,device_token,class_name,section,enroll_no")
          .eq("school_code", schoolCode).range(offset, offset + 999);
        if (error) return json({ error: "STUDENT_SUBSCRIPTION_LOOKUP_FAILED" }, 500);
        const batch = (data || []) as StudentPushRow[];
        rows.push(...batch);
        if (batch.length < 1000) break;
      }
      const matched = allStudents ? rows : rows.filter((row) =>
        targetScopes.some((scope) => scope.class_name === String(row.class_name || "").trim() &&
          scope.section.toLowerCase() === String(row.section || "").trim().toLowerCase()));
      const webRows = matched.filter((row) => row.platform === "web");
      const androidRows = matched.filter((row) => row.platform === "android");
      if (webPushConfigured && webRows.length) webpush.setVapidDetails(vapidSubject, vapidPublic, vapidPrivate);

      let fcmAccessToken = "";
      let androidConfigured = Boolean(fcmAccount);
      if (androidRows.length && fcmAccount) {
        try { fcmAccessToken = await getFcmAccessToken(fcmAccount); }
        catch (error) { androidConfigured = false; console.error("FCM token setup failed:", (error as Error)?.message || "unknown error"); }
      }

      let sentWeb = 0, sentAndroid = 0, failed = 0, skipped = 0;
      const jobs: Array<Promise<void>> = [];
      const recordDelivery = async (row: StudentPushRow, status: "success" | "failed", errorCode: string | null = null) => {
        const enrollNo = String(row.enroll_no || "").trim().toUpperCase();
        if (!enrollNo) return;
        const { error } = await service.from("student_activity_monitor").insert({
          school_code: schoolCode, enroll_no: enrollNo, class_name: row.class_name || null,
          section: row.section || null, platform: row.platform, event_type: "push_delivery",
          status
        });
        if (error) console.error("Push delivery monitor insert failed:", error.message);
      };
      for (const row of webRows) {
        if (!webPushConfigured) { skipped++; continue; }
        jobs.push(sendWebPush(row, title, message, category, service).then(async (ok) => {
          if (ok) { sentWeb++; await recordDelivery(row, "success"); }
          else { failed++; await recordDelivery(row, "failed", "WEB_PUSH_FAILED"); }
        }));
      }
      for (const row of androidRows) {
        if (!fcmAccessToken || !fcmAccount) { skipped++; continue; }
        jobs.push(sendFcm(fcmAccessToken, fcmAccount.project_id, String(row.device_token || ""), title, message, category).then(async (result) => {
          if (result.ok) { sentAndroid++; await recordDelivery(row, "success"); }
          else {
            failed++; await recordDelivery(row, "failed", result.detail || ("HTTP_" + result.status));
            if (result.detail === "UNREGISTERED" || result.status === 404) {
              await service.from("student_push_subscriptions").delete().eq("id", row.id);
            }
          }
        }));
      }
      for (let i = 0; i < jobs.length; i += 20) await Promise.allSettled(jobs.slice(i, i + 20));
      return json({
        success: true, subscriptionsFound: matched.length, sent: sentWeb + sentAndroid,
        sentWeb, sentAndroid, failed, skipped,
        webPushConfigured, androidPushConfigured: androidConfigured,
        message: matched.length === 0 ? "No student devices have registered yet." :
          sentWeb + sentAndroid === 0 ? "No push notifications were delivered; check device registration and delivery configuration." :
          "Push notifications processed.",
      });
    }

    const userIds = Array.isArray(body.userIds) ? body.userIds.map(String).filter((id) => /^[0-9a-f-]{36}$/i.test(id)).slice(0, 500) : [];
    if (!userIds.length) return json({ error: "INVALID_NOTIFICATION" }, 400);
    const { data: rows, error } = await service.from("push_subscriptions")
      .select("id,subscription,device_token,platform,user_id").in("user_id", userIds);
    if (error) return json({ error: "SUBSCRIPTION_LOOKUP_FAILED" }, 500);
    if (webPushConfigured) webpush.setVapidDetails(vapidSubject, vapidPublic, vapidPrivate);
    let fcmAccessToken = "";
    if (fcmAccount && (rows || []).some((row) => row.platform === "android")) {
      try { fcmAccessToken = await getFcmAccessToken(fcmAccount); }
      catch (error) { console.error("FCM token setup failed:", (error as Error)?.message || "unknown error"); }
    }
    let sent = 0, failed = 0, skipped = 0;
    for (const row of rows || []) {
      try {
        if (row.platform === "web" && webPushConfigured && row.subscription) {
          await webpush.sendNotification(row.subscription, JSON.stringify({ title, body: message, category, tag: category + ":" + crypto.randomUUID() }));
          sent++;
        } else if (row.platform === "android" && fcmAccessToken && fcmAccount && row.device_token) {
          const result = await sendFcm(fcmAccessToken, fcmAccount.project_id, row.device_token, title, message, category);
          if (result.ok) sent++;
          else { failed++; if (result.detail === "UNREGISTERED" || result.status === 404) await service.from("push_subscriptions").delete().eq("id", row.id); }
        } else skipped++;
      } catch (error) {
        failed++;
        const status = Number((error as { statusCode?: number })?.statusCode || 0);
        if ((status === 404 || status === 410) && row.id) await service.from("push_subscriptions").delete().eq("id", row.id);
      }
    }
    return json({ success: true, sent, failed, skipped, androidPushConfigured: Boolean(fcmAccessToken), webPushConfigured });
  }

  return json({ error: "UNKNOWN_ACTION" }, 400);
});
