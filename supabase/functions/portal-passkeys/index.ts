import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import {
  generateRegistrationOptions,
  verifyRegistrationResponse,
  generateAuthenticationOptions,
  verifyAuthenticationResponse,
} from "npm:@simplewebauthn/server@13.1.2";

const WEB_ORIGIN = "https://erskgaur2008-arch.github.io";
const RP_ID = "erskgaur2008-arch.github.io";
const RP_NAME = "Ashiana Public School Attendance";
const CORS_ORIGINS = new Set([WEB_ORIGIN, "https://localhost"]);
const androidOrigins = (Deno.env.get("ANDROID_PASSKEY_ORIGINS") || "")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);
const validAndroidOrigins = androidOrigins.filter((origin) =>
  /^android:apk-key-hash:[A-Za-z0-9_-]{43}$/.test(origin)
);
for (const origin of androidOrigins) {
  if (!validAndroidOrigins.includes(origin)) {
    console.error("Ignoring malformed ANDROID_PASSKEY_ORIGINS entry.");
  }
}
const EXPECTED_ORIGINS = [...new Set([WEB_ORIGIN, ...validAndroidOrigins])];

const b64 = (value: Uint8Array) => {
  let raw = "";
  for (let i = 0; i < value.length; i += 8192) {
    raw += String.fromCharCode(...value.subarray(i, i + 8192));
  }
  return btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
};
const unb64 = (value: string) =>
  Uint8Array.from(
    atob(value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4)),
    (character) => character.charCodeAt(0),
  );
const challenge = () => b64(crypto.getRandomValues(new Uint8Array(32)));
const hash = async (value: string) =>
  Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
const escapeLike = (value: string) => value.replace(/[\\%_]/g, (character) => "\\" + character);

Deno.serve(async (req) => {
  const origin = req.headers.get("Origin");
  const headers = new Headers({
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Vary": "Origin",
  });
  if (origin && CORS_ORIGINS.has(origin)) headers.set("Access-Control-Allow-Origin", origin);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers });

  if (origin && !CORS_ORIGINS.has(origin)) return json({ error: "ORIGIN_NOT_ALLOWED" }, 403);
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return json({ error: "SERVER_CONFIGURATION_ERROR" }, 503);
  const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "INVALID_JSON" }, 400);
  }

  const role = String(body.role || "");
  const action = String(body.action || "");
  const studentSessionUnlock = role === "student" && Boolean(String(body.session_token || "").trim());
  if (!(["admin", "student"] as string[]).includes(role)) return json({ error: "INVALID_ROLE" }, 400);

  let subjectId = "";
  let student: Record<string, unknown> | null = null;
  if (role === "admin") {
    const authorization = req.headers.get("Authorization") || "";
    const jwt = authorization.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
    if (!jwt) return json({ error: "AUTHENTICATION_REQUIRED" }, 401);
    const { data: authData, error: authError } = await db.auth.getUser(jwt);
    const email = String(authData.user?.email || "").trim().toLowerCase();
    if (authError || !email) return json({ error: "AUTHENTICATION_REQUIRED" }, 401);
    const { data: admins, error } = await db.from("admin_users").select("email,role").eq("active", true).limit(500);
    const matches = (admins || []).filter((row: { email: string }) =>
      String(row.email || "").trim().toLowerCase() === email
    );
    if (error || matches.length !== 1) return json({ error: "ADMIN_REQUIRED" }, 403);
    subjectId = email;
  } else if ((action === "authentication-options" || action === "authentication-verify") && role === "student") {
    const session = String(body.session_token || "").trim();
    if (session) {
      if (!/^[a-f0-9]{64}$/i.test(session)) return json({ error: "STUDENT_SESSION_REQUIRED" }, 401);
      const { data: id, error } = await db.rpc("student_session_student_id", { p_token: session });
      if (error || typeof id !== "string" || !id) return json({ error: "STUDENT_SESSION_EXPIRED" }, 401);
      subjectId = id;
      const { data: row, error: rosterError } = await db.from("student_roster")
        .select("id,enroll_no,name:student_name,status,school_code")
        .eq("id", id).eq("school_code", "ashiana").maybeSingle();
      if (rosterError || !row || String(row.status || "").toLowerCase() !== "active") {
        return json({ error: "STUDENT_SESSION_EXPIRED" }, 401);
      }
      student = row;
    } else {
      const enrollment = String(body.admission_no || "").trim();
      if (!enrollment || enrollment.length > 100) return json({ error: "ADMISSION_NUMBER_REQUIRED" }, 400);
      const { data: rows, error } = await db.from("student_roster")
        .select("id,enroll_no,name:student_name,status,school_code")
        .eq("school_code", "ashiana")
        .ilike("enroll_no", escapeLike(enrollment))
        .limit(2);
      if (error || !rows || rows.length !== 1 || String(rows[0].status || "").toLowerCase() !== "active") {
        return json({ error: "PASSKEY_LOGIN_UNAVAILABLE" }, 401);
      }
      student = rows[0];
      subjectId = String(student.id);
    }
  } else {
    const session = String(body.session_token || "").trim();
    if (!/^[a-f0-9]{64}$/i.test(session)) return json({ error: "STUDENT_SESSION_REQUIRED" }, 401);
    const { data: id, error } = await db.rpc("student_session_student_id", { p_token: session });
    if (error || typeof id !== "string" || !id) return json({ error: "STUDENT_SESSION_EXPIRED" }, 401);
    subjectId = id;
    const { data: row, error: rosterError } = await db.from("student_roster")
      .select("id,enroll_no,name:student_name,status,school_code")
      .eq("id", id).eq("school_code", "ashiana").maybeSingle();
    if (rosterError || !row || String(row.status || "").toLowerCase() !== "active") {
      return json({ error: "STUDENT_SESSION_EXPIRED" }, 401);
    }
    student = row;
  }

  try {
    if (action === "status") {
      const { data, error } = await db.from("portal_webauthn_credentials")
        .select("id,enabled").eq("subject_type", role).eq("subject_id", subjectId);
      if (error) throw error;
      const rows = data || [];
      return json({ enabled: rows.some((row: { enabled: boolean }) => row.enabled), credential_count: rows.length });
    }

    if (action === "disable") {
      const { error } = await db.from("portal_webauthn_credentials")
        .update({ enabled: false }).eq("subject_type", role).eq("subject_id", subjectId);
      if (error) throw error;
      return json({ success: true, enabled: false });
    }

    if (action === "enable") {
      const { data: existing, error } = await db.from("portal_webauthn_credentials")
        .select("id").eq("subject_type", role).eq("subject_id", subjectId);
      if (error) throw error;
      if (!existing?.length) return json({ error: "PASSKEY_NOT_REGISTERED" }, 404);
      const { error: updateError } = await db.from("portal_webauthn_credentials")
        .update({ enabled: true }).eq("subject_type", role).eq("subject_id", subjectId);
      if (updateError) throw updateError;
      return json({ success: true, enabled: true });
    }

    if (action === "registration-options") {
      const { data: existing, error } = await db.from("portal_webauthn_credentials")
        .select("credential_id").eq("subject_type", role).eq("subject_id", subjectId);
      if (error) throw error;
      const options = await generateRegistrationOptions({
        rpName: RP_NAME,
        rpID: RP_ID,
        userID: new TextEncoder().encode(role + ":" + subjectId),
        userName: role === "admin" ? subjectId : String(student?.enroll_no || subjectId),
        userDisplayName: String(student?.name || (role === "admin" ? "Ashiana Administrator" : "Ashiana Student")),
        attestationType: "none",
        authenticatorSelection: { residentKey: "preferred", userVerification: "required" },
        excludeCredentials: (existing || []).map((row: { credential_id: string }) => ({
          id: row.credential_id,
          type: "public-key" as const,
        })),
        challenge: challenge(),
      });
      await db.from("portal_webauthn_challenges").delete()
        .eq("subject_type", role).eq("subject_id", subjectId).eq("purpose", "registration");
      const { error: insertError } = await db.from("portal_webauthn_challenges").insert({
        subject_type: role,
        subject_id: subjectId,
        challenge: options.challenge,
        purpose: "registration",
        expires_at: new Date(Date.now() + 300_000).toISOString(),
      });
      if (insertError) throw insertError;
      return json({ options });
    }

    if (action === "registration-verify") {
      const credential = body.credential as { id?: string; response?: { transports?: string[] } } | undefined;
      if (!credential || typeof credential.id !== "string") return json({ error: "INVALID_CREDENTIAL" }, 400);
      const { data: storedChallenge, error } = await db.rpc("consume_portal_webauthn_challenge", {
        p_subject_type: role,
        p_subject_id: subjectId,
        p_purpose: "registration",
      });
      if (error) throw error;
      if (typeof storedChallenge !== "string" || !storedChallenge) return json({ error: "CHALLENGE_EXPIRED" }, 400);
      const result = await verifyRegistrationResponse({
        response: credential as never,
        expectedChallenge: storedChallenge,
        expectedOrigin: EXPECTED_ORIGINS,
        expectedRPID: RP_ID,
        requireUserVerification: true,
      });
      if (!result.verified || !result.registrationInfo) return json({ error: "PASSKEY_VERIFICATION_FAILED" }, 401);
      const info = result.registrationInfo;
      const credentialId = info.credential.id;
      const { data: owner, error: ownerError } = await db.from("portal_webauthn_credentials")
        .select("subject_type,subject_id").eq("credential_id", credentialId).maybeSingle();
      if (ownerError) throw ownerError;
      if (owner && (owner.subject_type !== role || owner.subject_id !== subjectId)) {
        return json({ error: "CREDENTIAL_ALREADY_BOUND" }, 409);
      }
      if (owner) return json({ success: true, already_registered: true });
      const { error: saveError } = await db.from("portal_webauthn_credentials").insert({
        subject_type: role,
        subject_id: subjectId,
        credential_id: credentialId,
        public_key: b64(info.credential.publicKey),
        counter: info.credential.counter,
        transports: credential.response?.transports || [],
        device_type: info.credentialDeviceType,
        backed_up: info.credentialBackedUp,
      });
      if (saveError?.code === "23505") return json({ error: "CREDENTIAL_ALREADY_BOUND" }, 409);
      if (saveError) throw saveError;
      return json({ success: true, enabled: true });
    }

    if (action === "authentication-options") {
      const { data: credentials, error } = await db.from("portal_webauthn_credentials")
        .select("credential_id,transports")
        .eq("subject_type", role).eq("subject_id", subjectId).eq("enabled", true);
      if (error) throw error;
      if (!credentials?.length) return json({ error: "PASSKEY_LOGIN_UNAVAILABLE" }, 401);
      const options = await generateAuthenticationOptions({
        rpID: RP_ID,
        userVerification: "required",
        allowCredentials: credentials.map((row: { credential_id: string; transports?: string[] }) => ({
          id: row.credential_id,
          transports: row.transports as never,
        })),
        challenge: challenge(),
      });
      await db.from("portal_webauthn_challenges").delete()
        .eq("subject_type", role).eq("subject_id", subjectId).eq("purpose", "authentication");
      const { error: insertError } = await db.from("portal_webauthn_challenges").insert({
        subject_type: role,
        subject_id: subjectId,
        challenge: options.challenge,
        purpose: "authentication",
        expires_at: new Date(Date.now() + 120_000).toISOString(),
      });
      if (insertError) throw insertError;
      return json({ options });
    }

    if (action === "authentication-verify") {
      const assertion = body.credential as { id?: string } | undefined;
      if (!assertion || typeof assertion.id !== "string") return json({ error: "INVALID_CREDENTIAL" }, 400);
      const { data: storedChallenge, error } = await db.rpc("consume_portal_webauthn_challenge", {
        p_subject_type: role,
        p_subject_id: subjectId,
        p_purpose: "authentication",
      });
      if (error) throw error;
      if (typeof storedChallenge !== "string" || !storedChallenge) return json({ error: "CHALLENGE_EXPIRED" }, 400);
      const { data: credentials, error: credentialError } = await db.from("portal_webauthn_credentials")
        .select("id,credential_id,public_key,counter,transports,enabled")
        .eq("subject_type", role).eq("subject_id", subjectId)
        .eq("credential_id", assertion.id).eq("enabled", true).limit(1);
      if (credentialError) throw credentialError;
      const stored = credentials?.[0];
      if (!stored) return json({ error: "PASSKEY_NOT_REGISTERED" }, 403);
      const verified = await verifyAuthenticationResponse({
        response: body.credential as never,
        expectedChallenge: storedChallenge,
        expectedOrigin: EXPECTED_ORIGINS,
        expectedRPID: RP_ID,
        credential: {
          id: stored.credential_id,
          publicKey: unb64(stored.public_key),
          counter: Number(stored.counter),
          transports: stored.transports || [],
        },
        requireUserVerification: true,
      });
      if (!verified.verified) return json({ error: "PASSKEY_VERIFICATION_FAILED" }, 401);
      const { error: updateError } = await db.from("portal_webauthn_credentials")
        .update({ counter: verified.authenticationInfo.newCounter, last_used_at: new Date().toISOString() })
        .eq("id", stored.id).eq("subject_type", role).eq("subject_id", subjectId);
      if (updateError) throw updateError;

      if (role === "admin" || studentSessionUnlock) {
        return json({ success: true, verified: true, purpose: "portal-unlock" });
      }
      const sessionToken = Array.from(crypto.getRandomValues(new Uint8Array(32)), (byte) =>
        byte.toString(16).padStart(2, "0")
      ).join("");
      const { error: sessionError } = await db.from("student_session_tokens").insert({
        student_id: subjectId,
        token_hash: await hash(sessionToken),
        expires_at: new Date(Date.now() + 30 * 24 * 60 * 60_000).toISOString(),
      });
      if (sessionError) throw sessionError;
      return json({ success: true, verified: true, session_token: sessionToken, expires_in: 2_592_000 });
    }

    return json({ error: "UNKNOWN_ACTION" }, 400);
  } catch (error) {
    console.error("portal-passkeys error:", error instanceof Error ? error.message : String(error));
    return json({ error: "PASSKEY_OPERATION_FAILED" }, 500);
  }
});
