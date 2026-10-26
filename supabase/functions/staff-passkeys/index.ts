// Staff WebAuthn passkey enrollment and verification for the Ashiana PWA.
// Public-key credentials only: this function never receives or stores biometric images.
// Requires staff JWT. Attendance enforcement must consume a verified, short-lived
// server-side assertion before recording any punch; a successful browser prompt alone
// must never be treated as attendance authorization.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import {
  generateRegistrationOptions,
  verifyRegistrationResponse,
  generateAuthenticationOptions,
  verifyAuthenticationResponse,
} from "npm:@simplewebauthn/server@13.1.2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
});
const b64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
const fromB64url = (value: string) => {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(normalized + "=".repeat((4 - normalized.length % 4) % 4));
  return Uint8Array.from(raw, c => c.charCodeAt(0));
};
const randomChallenge = () => b64url(crypto.getRandomValues(new Uint8Array(32)));
const sha256Hex = async (value: string) => {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
};
const requestIP = (req: Request) => req.headers.get("cf-connecting-ip") || req.headers.get("x-real-ip") || "unknown";
const rpID = "erskgaur2008-arch.github.io";
const expectedOrigin = "https://erskgaur2008-arch.github.io";
const rpName = "Ashiana Public School Attendance";

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
    const email = authData.user?.email?.trim().toLowerCase();
    if (authError || !email) return json({ error: "AUTHENTICATION_REQUIRED" }, 401);

    const { data: staffRows, error: staffError } = await admin.from("staff")
      .select("id,emp_id,name,email,status,valid_thru")
      .ilike("email", email).eq("status", "ACTIVE").limit(2);
    if (staffError || !staffRows || staffRows.length !== 1) return json({ error: "STAFF_PROFILE_NOT_LINKED" }, 403);
    const staff = staffRows[0];
    if (staff.valid_thru && new Date(staff.valid_thru + "T00:00:00Z") < new Date(new Date().toISOString().slice(0, 10) + "T00:00:00Z")) {
      return json({ error: "ID_CARD_EXPIRED" }, 403);
    }

    const body = await req.json().catch(() => ({}));
    const action = String(body?.action || "");
    const now = Date.now();

    if (action === "registration-options") {
      // Re-authenticate with the current PIN before allowing a new authenticator
      // to be linked. Reuse the existing server-side PIN verifier and shared
      // rate-limit buckets; never trust a PIN supplied by the browser alone.
      const currentPin = String(body?.current_pin || "").trim();
      if (!/^\d{4}$/.test(currentPin)) return json({ error: "CURRENT_PIN_REQUIRED" }, 400);
      const ip = requestIP(req);
      const ipDigest = await sha256Hex("staff-ip:" + ip);
      const staffDigest = await sha256Hex("staff:" + String(staff.id));
      const ipLimit = await admin.rpc("consume_staff_login_attempt", {
        p_login_key: ipDigest, p_max_attempts: 60, p_window_seconds: 600,
      });
      if (ipLimit.error) throw ipLimit.error;
      if (ipLimit.data?.allowed === false) return json({ error: "RATE_LIMIT", retry_after_seconds: ipLimit.data.retry_after_seconds || 600 }, 429);
      const staffLimit = await admin.rpc("consume_staff_login_attempt", {
        p_login_key: staffDigest, p_max_attempts: 5, p_window_seconds: 900,
      });
      if (staffLimit.error) throw staffLimit.error;
      if (staffLimit.data?.allowed === false) return json({ error: "RATE_LIMIT", retry_after_seconds: staffLimit.data.retry_after_seconds || 900 }, 429);
      const pinCheck = await admin.rpc("verify_staff_pin_internal", {
        p_staff_id: staff.id, p_pin: currentPin,
      });
      if (pinCheck.error) throw pinCheck.error;
      if (pinCheck.data !== true) return json({ error: "INVALID_PIN" }, 401);
      await admin.rpc("clear_staff_login_attempt", { p_login_key: staffDigest });

      const { data: existing, error } = await admin.from("staff_webauthn_credentials")
        .select("credential_id").eq("staff_id", String(staff.id));
      if (error) throw error;
      const challenge = randomChallenge();
      const options = await generateRegistrationOptions({
        rpName, rpID,
        userName: String(staff.emp_id || staff.email || staff.id),
        userDisplayName: String(staff.name || "Ashiana Staff"),
        userID: new TextEncoder().encode(String(staff.id)),
        attestationType: "none",
        authenticatorSelection: { residentKey: "preferred", userVerification: "required" },
        excludeCredentials: (existing || []).map((row: { credential_id: string }) => ({ id: row.credential_id, type: "public-key" as const })),
        challenge,
      });
      const { error: clearError } = await admin.from("staff_webauthn_challenges").delete()
        .eq("staff_id", String(staff.id)).eq("purpose", "registration");
      if (clearError) throw clearError;
      const { error: insertError } = await admin.from("staff_webauthn_challenges").insert({
        staff_id: String(staff.id), challenge: options.challenge, purpose: "registration",
        expires_at: new Date(now + 5 * 60_000).toISOString(),
      });
      if (insertError) throw insertError;
      return json({ options });
    }

    if (action === "registration-verify") {
      const credential = body?.credential;
      if (!credential || typeof credential.id !== "string") return json({ error: "INVALID_CREDENTIAL" }, 400);
      const { data: savedChallenge, error: challengeError } = await admin.rpc("consume_staff_webauthn_challenge", {
        p_staff_id: String(staff.id), p_purpose: "registration",
      });
      if (challengeError) throw challengeError;
      if (typeof savedChallenge !== "string" || !savedChallenge) return json({ error: "CHALLENGE_EXPIRED" }, 400);
      const result = await verifyRegistrationResponse({
        response: credential,
        expectedChallenge: savedChallenge,
        expectedOrigin,
        expectedRPID: rpID,
        requireUserVerification: true,
      });
      if (!result.verified || !result.registrationInfo) return json({ error: "PASSKEY_VERIFICATION_FAILED" }, 401);
      const info = result.registrationInfo;
      const publicKey = b64url(info.credential.publicKey);
      const credentialId = info.credential.id;
      const { data: credentialOwner, error: ownerError } = await admin.from("staff_webauthn_credentials")
        .select("staff_id").eq("credential_id", credentialId).maybeSingle();
      if (ownerError) throw ownerError;
      if (credentialOwner && String(credentialOwner.staff_id) !== String(staff.id)) {
        return json({ error: "CREDENTIAL_ALREADY_BOUND" }, 409);
      }
      const { error: saveError } = await admin.from("staff_webauthn_credentials").upsert({
        staff_id: String(staff.id), credential_id: credentialId, public_key: publicKey,
        counter: info.credential.counter, transports: credential.response?.transports || [],
        device_type: info.credentialDeviceType, backed_up: info.credentialBackedUp,
      }, { onConflict: "credential_id" });
      if (saveError) throw saveError;
      return json({ success: true });
    }

    if (action === "authentication-options") {
      const { data: credentials, error } = await admin.from("staff_webauthn_credentials")
        .select("credential_id,transports").eq("staff_id", String(staff.id));
      if (error) throw error;
      if (!credentials?.length) return json({ error: "PASSKEY_NOT_REGISTERED" }, 404);
      const options = await generateAuthenticationOptions({
        rpID, userVerification: "required",
        allowCredentials: credentials.map((row: { credential_id: string; transports?: string[] }) => ({
          id: row.credential_id, type: "public-key" as const,
          transports: row.transports || [],
        })),
        challenge: randomChallenge(),
      });
      const { error: clearError } = await admin.from("staff_webauthn_challenges").delete()
        .eq("staff_id", String(staff.id)).eq("purpose", "attendance");
      if (clearError) throw clearError;
      const { error: insertError } = await admin.from("staff_webauthn_challenges").insert({
        staff_id: String(staff.id), challenge: options.challenge, purpose: "attendance",
        expires_at: new Date(now + 2 * 60_000).toISOString(),
      });
      if (insertError) throw insertError;
      return json({ options });
    }

    if (action === "authentication-verify") {
      const assertion = body?.credential;
      if (!assertion || typeof assertion.id !== "string") return json({ error: "INVALID_CREDENTIAL" }, 400);
      const { data: challengeValue, error: challengeError } = await admin.rpc("consume_staff_webauthn_challenge", {
        p_staff_id: String(staff.id), p_purpose: "attendance",
      });
      if (challengeError) throw challengeError;
      if (typeof challengeValue !== "string" || !challengeValue) return json({ error: "CHALLENGE_EXPIRED" }, 400);

      const { data: rows, error: credentialError } = await admin.from("staff_webauthn_credentials")
        .select("id,credential_id,public_key,counter,transports")
        .eq("staff_id", String(staff.id)).eq("credential_id", assertion.id).limit(1);
      if (credentialError) throw credentialError;
      const stored = rows?.[0];
      if (!stored) return json({ error: "PASSKEY_NOT_REGISTERED" }, 403);

      const result = await verifyAuthenticationResponse({
        response: assertion,
        expectedChallenge: challengeValue,
        expectedOrigin,
        expectedRPID: rpID,
        credential: {
          id: stored.credential_id,
          publicKey: fromB64url(stored.public_key),
          counter: Number(stored.counter),
          transports: stored.transports || [],
        },
        requireUserVerification: true,
      });
      // Challenge was atomically consumed before signature verification, so replay is blocked.
      if (!result.verified) return json({ error: "PASSKEY_VERIFICATION_FAILED" }, 401);

      const { error: updateError } = await admin.from("staff_webauthn_credentials").update({
        counter: result.authenticationInfo.newCounter, last_used_at: new Date().toISOString(),
      }).eq("id", stored.id).eq("staff_id", String(staff.id));
      if (updateError) throw updateError;
      // Mint a random one-time token. Only its hash is stored; verify-attendance
      // atomically consumes it so the same biometric assertion cannot authorize
      // multiple punches. Token is bound to this staff row and expires quickly.
      const rawToken = randomChallenge() + randomChallenge();
      const tokenDigest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(rawToken)));
      const tokenHash = Array.from(tokenDigest, byte => byte.toString(16).padStart(2, "0")).join("");
      const { error: tokenError } = await admin.from("staff_webauthn_verified_sessions").insert({
        token_hash: tokenHash,
        staff_id: String(staff.id),
        expires_at: new Date(Date.now() + 90_000).toISOString(),
      });
      if (tokenError) throw tokenError;
      return json({ success: true, verified: true, attendance_token: rawToken, expires_in: 90 });
    }

    return json({ error: "UNKNOWN_ACTION" }, 400);
  } catch (error) {
    console.error("staff-passkeys error:", error instanceof Error ? error.message : String(error));
    return json({ error: "SERVER_ERROR" }, 500);
  }
});
