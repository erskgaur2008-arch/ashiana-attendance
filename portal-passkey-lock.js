/* Server-verified passkey sign-in for Admin and Student portals. */
(() => {
  "use strict";
  const FN = "portal-passkeys";
  const STUDENT_TOKEN_KEY = "aps_student_session_token_v1";
  const ADMIN_AUTH_STORAGE_KEY = "sb-oalfzgluqroqbbrulhpr-auth-token";
  const RECENT_AUTH_KEY = "aps_passkey_recent_auth_v1";

  const bytesToB64u = value => {
    if (typeof value === "string") return value.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
    const bytes = value instanceof ArrayBuffer
      ? new Uint8Array(value)
      : ArrayBuffer.isView(value)
        ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
        : new Uint8Array(value || []);
    let raw = "";
    for (let i = 0; i < bytes.length; i += 8192) raw += String.fromCharCode(...bytes.subarray(i, i + 8192));
    return btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
  };
  const b64uToBytes = value => {
    const s = String(value || "").replace(/-/g, "+").replace(/_/g, "/");
    const raw = atob(s + "=".repeat((4 - s.length % 4) % 4));
    return Uint8Array.from(raw, c => c.charCodeAt(0));
  };
  const publicKeyOptions = options => {
    const out = { ...options, challenge: b64uToBytes(options.challenge) };
    if (options.user?.id) out.user = { ...options.user, id: b64uToBytes(options.user.id) };
    for (const key of ["allowCredentials", "excludeCredentials"]) {
      if (Array.isArray(options[key])) out[key] = options[key].map(c => ({ ...c, id: b64uToBytes(c.id) }));
    }
    return out;
  };
  const credentialJSON = async credential => {
    if (!credential?.response) throw new Error("The passkey provider returned an invalid response.");
    const response = credential.response;
    const result = {
      id: credential.id,
      rawId: bytesToB64u(credential.rawId),
      type: credential.type || "public-key",
      authenticatorAttachment: credential.authenticatorAttachment || undefined,
      clientExtensionResults: credential.getClientExtensionResults?.() || credential.clientExtensionResults || {},
      response: {}
    };
    if (response.attestationObject) {
      result.response.attestationObject = bytesToB64u(response.attestationObject);
      result.response.clientDataJSON = bytesToB64u(response.clientDataJSON);
      result.response.transports = response.transports || response.getTransports?.() || [];
    } else {
      result.response.authenticatorData = bytesToB64u(response.authenticatorData);
      result.response.clientDataJSON = bytesToB64u(response.clientDataJSON);
      result.response.signature = bytesToB64u(response.signature);
      if (response.userHandle) result.response.userHandle = bytesToB64u(response.userHandle);
    }
    return result;
  };

  async function authClient() {
    if (window.__ashianaMainSupabaseClient) return window.__ashianaMainSupabaseClient;
    if (typeof window.__ashianaGetMainSupabaseClient !== "function") {
      throw new Error("Authentication service is not ready. Please try again.");
    }
    return await window.__ashianaGetMainSupabaseClient();
  }

  let edgeClient = null;
  async function getEdgeClient() {
    if (edgeClient) return edgeClient;
    edgeClient = await authClient();
    return edgeClient;
  }
  async function invoke(role, action, extra = {}) {
    const supa = await getEdgeClient();
    const { data, error } = await supa.functions.invoke(FN, { body: { role, action, ...extra } });
    if (error) {
      let message = data?.error || error.message || "Passkey request failed.";
      try {
        const payload = await error.context?.clone?.().json();
        message = payload?.error || payload?.message || message;
      } catch (_) {}
      throw new Error(message);
    }
    if (data?.error) throw new Error(data.error);
    return data;
  }

  function currentRole() {
    try {
      const auth = JSON.parse(sessionStorage.getItem("aps_current_auth_session_v1") || "{}");
      if (auth.type === "ADMIN") return { role: "admin", auth };
      if (auth.type === "STUDENT") return { role: "student", auth };
    } catch (_) {}
    try {
      const student = JSON.parse(sessionStorage.getItem("aps_student_session_v1") || "{}");
      if (student.type === "STUDENT") return { role: "student", auth: student };
    } catch (_) {}
    return null;
  }
  const isNative = () => Boolean(window.AshianaNative?.isAndroid?.());
  const studentSessionToken = () =>
    String(sessionStorage.getItem(STUDENT_TOKEN_KEY) || localStorage.getItem(STUDENT_TOKEN_KEY) || "").trim();

  function toast(message, kind = "info") {
    if (typeof window.showToast === "function") { window.showToast(message, kind); return; }
    let el = document.getElementById("portal-passkey-status");
    if (!el) {
      el = document.createElement("div");
      el.id = "portal-passkey-status";
      el.setAttribute("role", "status");
      el.setAttribute("aria-live", "polite");
      el.style.cssText = "position:fixed;left:16px;right:16px;bottom:18px;z-index:2147483002;padding:12px 14px;border-radius:12px;background:#064e3b;color:#fff;font:600 13px system-ui,sans-serif";
      document.body.append(el);
    }
    el.textContent = message;
    el.style.background = kind === "error" ? "#991b1b" : "#064e3b";
  }

  async function ensurePasskeyRuntime() {
    if (isNative()) {
      if (typeof window.AshianaNative?.ensurePasskeyReady !== "function") {
        throw new Error("Update the Android app to enable native passkey sign-in.");
      }
      await window.AshianaNative.ensurePasskeyReady();
    } else if (!navigator.credentials?.create || !navigator.credentials?.get) {
      throw new Error("This browser does not support secure passkeys. Use a current browser over HTTPS.");
    }
  }

  async function passkeyStatus(role) {
    if (role === "admin") {
      const client = await authClient();
      const listPasskeys = client.auth.passkey?.list;
      if (typeof listPasskeys !== "function") throw new Error("This Supabase client does not include Admin passkey support.");
      const { data, error } = await client.auth.passkey.list();
      if (error) throw error;
      const count = Array.isArray(data) ? data.length : 0;
      return { enabled: count > 0, credential_count: count };
    }
    const token = studentSessionToken();
    if (!token) throw new Error("Student session is unavailable. Sign in with Admission No. and DOB first.");
    return await invoke("student", "status", { session_token: token });
  }

  async function registerPasskey(role) {
    await ensurePasskeyRuntime();
    if (role === "admin") {
      const client = await authClient();
      if (typeof client.auth.registerPasskey !== "function") throw new Error("Admin passkey registration is unavailable in this app version.");
      const { data, error } = await client.auth.registerPasskey();
      if (error || !data) throw new Error(error?.message || "Admin passkey registration failed.");
      return true;
    }

    const token = studentSessionToken();
    if (!/^[a-f0-9]{64}$/i.test(token)) throw new Error("Student session expired. Sign in with Admission No. and DOB again.");
    const extra = { session_token: token };
    const { options } = await invoke("student", "registration-options", extra);
    const credential = await navigator.credentials.create({ publicKey: publicKeyOptions(options) });
    if (!credential) throw new Error("Passkey registration was cancelled.");
    const result = await invoke("student", "registration-verify", {
      ...extra,
      credential: await credentialJSON(credential)
    });
    if (!result.success) throw new Error("Student passkey registration could not be completed.");
    return true;
  }

  const webPasskeyEnabled = { admin: false, student: false };
  const freshAuthHandled = { admin: false, student: false };
  let overlay = null;
  let idleTimer = null;
  let setupPrompted = { admin: false, student: false };

  function consumeRecentAuthentication(role) {
    if (freshAuthHandled[role]) return true;
    freshAuthHandled[role] = true;
    try {
      const recent = sessionStorage.getItem(RECENT_AUTH_KEY);
      if (recent) sessionStorage.removeItem(RECENT_AUTH_KEY);
      return recent === role;
    } catch (_) { return false; }
  }

  async function authenticateAdminPasskey(purpose) {
    const before = currentRole();
    const expectedEmail = String(before?.auth?.username || before?.auth?.email || "").trim().toLowerCase();
    const client = await authClient();
    const { data, error } = await client.auth.signInWithPasskey();
    if (error || !data?.user) throw new Error(error?.message || "Admin passkey verification failed.");
    const verified = await client.auth.getUser();
    const email = String(verified.data?.user?.email || data.user.email || "").trim().toLowerCase();
    const { data: authorization, error: authorizationError } = await client.rpc("authorize_admin_login");
    if (verified.error || authorizationError || !authorization?.authorized || !email) {
      await client.auth.signOut({ scope: "local" });
      throw new Error(authorizationError?.message || "This passkey is not authorized for the Admin portal.");
    }
    if (purpose === "unlock" && (!expectedEmail || email !== expectedEmail)) {
      await client.auth.signOut({ scope: "local" });
      throw new Error("The passkey account could not be matched to this Admin session. Sign in again with the correct account.");
    }
    webPasskeyEnabled.admin = true;
    if (purpose === "unlock") unlockOverlay();
    return true;
  }

  async function authenticateStudentPasskey(purpose) {
    const extra = {};
    if (purpose === "unlock") {
      const token = studentSessionToken();
      if (!/^[a-f0-9]{64}$/i.test(token)) throw new Error("Student session expired. Sign in again with Admission No. and DOB.");
      extra.session_token = token;
    } // Fresh student sign-in uses a discoverable passkey; no Admission No. or DOB is needed.

    const { options } = await invoke("student", "authentication-options", extra);
    const credential = await navigator.credentials.get({ publicKey: publicKeyOptions(options) });
    if (!credential) throw new Error("Passkey verification was cancelled.");
    const result = await invoke("student", "authentication-verify", {
      ...extra,
      credential: await credentialJSON(credential)
    });
    if (!result.success) throw new Error("Student passkey verification failed.");

    if (purpose === "unlock") {
      unlockOverlay();
      return true;
    }
    const token = String(result.session_token || "");
    if (!/^[a-f0-9]{64}$/i.test(token)) throw new Error("Student session token is invalid.");

    // Student portals use opaque student-session tokens, never an Admin Auth
    // session. Revoke any other local Supabase identity before switching roles.
    window.__ashianaLoginBusy = true;
    try {
      const client = await authClient();
      await client.auth.signOut({ scope: "local" });
    } catch (error) {
      console.warn("Local Auth cleanup before Student passkey sign-in:", error?.message || error);
    }
    try { localStorage.removeItem(ADMIN_AUTH_STORAGE_KEY); } catch (_) {}
    try { sessionStorage.removeItem(ADMIN_AUTH_STORAGE_KEY); } catch (_) {}
    sessionStorage.removeItem("aps_admin_login_handoff_v1");
    sessionStorage.removeItem("aps_login_handoff_v1");
    sessionStorage.setItem(STUDENT_TOKEN_KEY, token);
    sessionStorage.setItem(RECENT_AUTH_KEY, "student");
    if (isNative()) {
      await window.AshianaNative.saveStudentSessionToken(token);
      try { localStorage.removeItem(STUDENT_TOKEN_KEY); } catch (_) {}
    } else {
      localStorage.setItem(STUDENT_TOKEN_KEY, token);
    }
    location.reload();
    return true;
  }

  async function authenticatePasskey(role, purpose = "unlock") {
    await ensurePasskeyRuntime();
    if (role === "admin") return authenticateAdminPasskey(purpose);
    return authenticateStudentPasskey(purpose);
  }

  function armIdleLock(role) {
    clearTimeout(idleTimer);
    if (!role || !webPasskeyEnabled[role]) return;
    idleTimer = setTimeout(() => {
      if (currentRole()?.role === role) lockOverlay(role);
    }, 10 * 60 * 1000);
  }
  ["pointerdown", "keydown", "touchstart", "click"].forEach(eventName =>
    window.addEventListener(eventName, () => {
      const current = currentRole();
      if (current) armIdleLock(current.role);
    }, { passive: true })
  );

  function lockOverlay(role) {
    if (overlay || !webPasskeyEnabled[role]) return;
    clearTimeout(idleTimer);
    overlay = document.createElement("div");
    overlay.id = "portal-passkey-lock-overlay";
    overlay.style.cssText = "position:fixed;inset:0;z-index:2147483000;background:rgba(2,20,15,.97);display:flex;align-items:center;justify-content:center;padding:24px;color:white;font-family:system-ui,sans-serif";
    const card = document.createElement("div");
    card.style.cssText = "width:min(100%,380px);background:#064e3b;border:1px solid #34d399;border-radius:24px;padding:28px;text-align:center;box-shadow:0 24px 80px #0008";
    const title = document.createElement("h2");
    title.textContent = "Portal locked";
    title.style.cssText = "font-size:24px;font-weight:800;margin:0 0 8px";
    const desc = document.createElement("p");
    desc.textContent = "Verify your account passkey to continue.";
    desc.style.cssText = "font-size:14px;opacity:.9;margin:0 0 22px";
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Unlock with Passkey";
    button.style.cssText = "width:100%;padding:14px;border-radius:12px;background:white;color:#064e3b;font-weight:800";
    button.addEventListener("click", async () => {
      button.disabled = true;
      button.textContent = "Verifying passkey...";
      try {
        await authenticatePasskey(role, "unlock");
      } catch (error) {
        toast(error.message || "Passkey verification failed.", "error");
        button.disabled = false;
        button.textContent = "Unlock with Passkey";
      }
    });
    card.append(title, desc, button);
    overlay.append(card);
    document.body.append(overlay);
  }
  function unlockOverlay() {
    overlay?.remove();
    overlay = null;
    const current = currentRole();
    if (current) armIdleLock(current.role);
  }

  function setupDialog(role) {
    const dialog = document.createElement("div");
    dialog.id = "portal-passkey-setup-prompt";
    dialog.style.cssText = "position:fixed;inset:0;z-index:2147483001;background:rgba(2,20,15,.78);display:flex;align-items:center;justify-content:center;padding:24px;font-family:system-ui,sans-serif";
    const accountName = role === "admin" ? "Admin" : "Student";
    dialog.innerHTML = '<section role="dialog" aria-modal="true" aria-labelledby="portal-passkey-setup-title" style="width:min(100%,380px);background:white;border-radius:22px;padding:24px;text-align:center;color:#064e3b"><div style="font-size:38px" aria-hidden="true">🔐</div><h2 id="portal-passkey-setup-title" style="font-size:22px;font-weight:800;margin:8px 0">Set up passkey sign-in</h2><p style="font-size:14px;margin:0 0 20px">Use this device or a synced password manager to sign in securely to your ' + accountName + ' account.</p><button type="button" data-passkey-setup="enable" style="width:100%;padding:13px;border-radius:12px;background:#064e3b;color:white;font-weight:800">Set up passkey</button><button type="button" data-passkey-setup="later" style="width:100%;padding:12px;margin-top:8px;color:#475569;font-weight:700">Not now</button></section>';
    dialog.addEventListener("click", async event => {
      const choice = event.target.closest("[data-passkey-setup]");
      if (!choice) return;
      if (choice.dataset.passkeySetup === "later") { dialog.remove(); return; }
      choice.disabled = true;
      try {
        await registerPasskey(role);
        webPasskeyEnabled[role] = true;
        sessionStorage.setItem(RECENT_AUTH_KEY, role);
        dialog.remove();
        toast("Passkey sign-in is now enabled for this " + accountName + " account.", "success");
        armIdleLock(role);
      } catch (error) {
        toast(error.message || "Passkey setup failed.", "error");
        choice.disabled = false;
      }
    });
    document.body.append(dialog);
  }

  async function offerPasskeySetup(role) {
    if (!role || setupPrompted[role]) return;
    setupPrompted[role] = true;
    try {
      const status = await passkeyStatus(role);
      webPasskeyEnabled[role] = Boolean(status.enabled);
      if (webPasskeyEnabled[role]) {
        armIdleLock(role);
        const recentlyAuthenticated = consumeRecentAuthentication(role);
        if (isNative() && !recentlyAuthenticated) lockOverlay(role);
        return;
      }
      setupDialog(role);
    } catch (error) {
      console.warn("Could not load " + role + " passkey status:", error?.message || error);
      if (role !== "student") {
        toast("Passkey setup is currently unavailable. You can continue with your usual sign-in.", "info");
      }
    }
  }

  let studentFingerprintSetupInFlight = false;

  async function authenticateStudentFingerprint() {
    const native = window.AshianaNative;
    if (!native?.isAndroid?.() || typeof native.getStudentBiometricSessionToken !== "function") {
      throw new Error("Fingerprint login is available only in the Android app. Use Admission No. and DOB.");
    }
    const deviceSecret = await native.getStudentBiometricSessionToken();
    // Exchange the biometric-protected device credential for a fresh,
    // revocable Student session. Logout never revokes the device credential.
    const client = await authClient();
    const { data: exchange, error: exchangeError } = await client.rpc("student_biometric_login", {
      p_device_secret: deviceSecret
    });
    if (exchangeError || !exchange?.success || !/^[a-f0-9]{64}$/i.test(String(exchange.session_token || ""))) {
      throw new Error("Student fingerprint sign-in could not be verified. Please use Admission No. and DOB.");
    }
    const token = String(exchange.session_token);
    try { await client.auth.signOut({ scope: "local" }); } catch (_) {}
    try { localStorage.removeItem(ADMIN_AUTH_STORAGE_KEY); } catch (_) {}
    try { sessionStorage.removeItem(ADMIN_AUTH_STORAGE_KEY); } catch (_) {}
    sessionStorage.setItem(STUDENT_TOKEN_KEY, token);
    sessionStorage.setItem(RECENT_AUTH_KEY, "student");
    await native.saveStudentSessionToken(token);
    location.reload();
    return true;
  }

  async function enableStudentFingerprint() {
    const native = window.AshianaNative;
    if (!native?.isAndroid?.() || typeof native.enableStudentBiometric !== "function") {
      throw new Error("Fingerprint enrollment is available only in the Android app.");
    }
    const token = studentSessionToken();
    if (!/^[a-f0-9]{64}$/i.test(token)) throw new Error("Please sign in with Admission No. and DOB before enabling fingerprint login.");
    await invoke("student", "status", { session_token: token });
    const deviceSecret = Array.from(crypto.getRandomValues(new Uint8Array(32)), byte => byte.toString(16).padStart(2, "0")).join("");
    const client = await authClient();
    const { data: enrolled, error: enrollError } = await client.rpc("student_biometric_enroll", {
      p_session_token: token,
      p_device_secret: deviceSecret
    });
    if (enrollError || !enrolled?.success) throw new Error("Could not register this phone for Student fingerprint login.");
    try { await native.enableStudentBiometric(deviceSecret); }
    catch (error) {
      try { await client.rpc("student_biometric_revoke", { p_device_secret: deviceSecret }); } catch (_) {}
      throw error;
    }
    toast("Student fingerprint login is enabled on this phone.", "success");
    document.getElementById("student-fingerprint-setup")?.remove();
  }

  let studentFingerprintControlsInstallInFlight = false;
  let studentFingerprintMenuRefreshInFlight = false;

  async function installStudentFingerprintLoginControls() {
    if (studentFingerprintControlsInstallInFlight || !isNative()) return;
    // Compact the Student-only green login banner on mobile and keep its
    // logo/title hierarchy intact. Other roles retain their existing layout.
    if (!document.getElementById("student-login-compact-hero-style")) {
      const style = document.createElement("style");
      style.id = "student-login-compact-hero-style";
      style.textContent = `
        @media (max-width: 640px) {
          #auth-gateway-view[data-login-role-active="student"] #login-hero {
            padding: 14px 14px 30px !important;
          }
          #auth-gateway-view[data-login-role-active="student"] #login-hero .login-school-logo {
            width: 72px !important;
            height: 72px !important;
            margin-bottom: 7px !important;
          }
          #auth-gateway-view[data-login-role-active="student"] #login-hero h2 {
            font-size: 1.25rem !important;
            line-height: 1.25 !important;
          }
          #auth-gateway-view[data-login-role-active="student"] #login-hero .login-school-subtitle {
            margin-top: 3px !important;
            font-size: .9rem !important;
          }
        }
      `;
      document.head.append(style);
    }
    const form = document.getElementById("student-login-form");
    if (!form) return;
    // Remove legacy separate fingerprint controls and any duplicate icon controls.
    for (const id of ["student-fingerprint-register", "student-fingerprint-remove", "student-fingerprint-login"]) {
      form.querySelectorAll("#" + id).forEach(node => node.remove());
    }
    let trigger = form.querySelector("#student-fingerprint-actions");
    if (!trigger) {
      trigger = document.createElement("button");
      trigger.id = "student-fingerprint-actions";
      trigger.type = "button";
      trigger.className = "flex items-center justify-center w-14 h-14 mt-3 mx-auto rounded-full border border-emerald-200 bg-emerald-50 text-emerald-800 shadow-sm";
      trigger.setAttribute("aria-label", "Student fingerprint options");
      trigger.setAttribute("aria-haspopup", "menu");
      trigger.setAttribute("aria-expanded", "false");
      trigger.innerHTML = '<svg viewBox="0 0 24 24" width="26" height="26" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 11a2 2 0 0 0-2 2c0 2.5-.3 4.4-1.2 6.2"/><path d="M14 13c0 3.1-.4 5.6-1.4 7.7"/><path d="M8.5 15.5c-.2 1.5-.6 2.8-1.3 4"/><path d="M6.5 13a5.5 5.5 0 0 1 11 0c0 1.1 0 2.1-.1 3"/><path d="M4.5 13a7.5 7.5 0 0 1 15 0"/><path d="M10 7.2a4 4 0 0 1 6 3.5"/><path d="M3 16.5c.5 1.3 1.1 2.4 1.9 3.4"/></svg>';
      form.append(trigger);
    }
    let menu = form.querySelector("#student-fingerprint-menu");
    if (!menu) {
      menu = document.createElement("div");
      menu.id = "student-fingerprint-menu";
      menu.className = "w-full mt-2 p-3 rounded-2xl border border-emerald-100 bg-white shadow-lg space-y-2";
      menu.hidden = true;
      menu.style.setProperty("display", "none", "important");
      menu.setAttribute("role", "menu");
      form.append(menu);
    }

    const refresh = async () => {
      if (studentFingerprintMenuRefreshInFlight) return;
      studentFingerprintMenuRefreshInFlight = true;
      try {
        const enrolled = await window.AshianaNative.hasStudentBiometricEnrollment();
        menu.replaceChildren();
        const addAction = (label, action, tone) => {
          const item = document.createElement("button");
          item.type = "button";
          item.role = "menuitem";
          item.textContent = label;
          item.className = "w-full py-3 px-4 rounded-xl text-sm font-semibold " + tone;
          item.addEventListener("click", action);
          menu.append(item);
        };

        if (enrolled) {
          addAction("Sign in with fingerprint", async () => {
            menu.hidden = true;
            menu.style.setProperty("display", "none", "important");
            trigger.setAttribute("aria-expanded", "false");
            try { await authenticateStudentFingerprint(); }
            catch (error) { toast(error.message || "Student fingerprint sign-in failed.", "error"); }
          }, "bg-emerald-800 text-white");
          addAction("Remove fingerprint login from this phone", async event => {
            const item = event.currentTarget;
            item.disabled = true;
            try {
              const deviceSecret = await window.AshianaNative.getStudentBiometricSessionToken();
              const client = await authClient();
              const { error } = await client.rpc("student_biometric_revoke", { p_device_secret: deviceSecret });
              if (error) throw new Error(error.message || "Could not revoke this phone's fingerprint registration.");
              await window.AshianaNative.disableStudentBiometric?.();
              toast("Student fingerprint login removed from this phone.", "success");
              await refresh();
            } catch (error) {
              toast(error.message || "Could not remove Student fingerprint login.", "error");
              item.disabled = false;
            }
          }, "bg-emerald-50 text-emerald-900 border border-emerald-200");
        } else {
          addAction("Register fingerprint for attendance", async event => {
            const item = event.currentTarget;
            const liveForm = document.getElementById("student-login-form");
            const fields = Array.from(liveForm?.querySelectorAll("input") || [])
              .filter(input => input.type !== "hidden" && !input.disabled);
            const admission = String(fields[0]?.value || "").trim();
            const dob = String(fields[1]?.value || "").replace(/\D/g, "");
            if (!admission || !/^\d{8}$/.test(dob)) {
              toast("Enter your Admission No. and DOB (DDMMYYYY) above, then register fingerprint.", "error");
              return;
            }
            item.disabled = true;
            item.textContent = "Registering fingerprint...";
            let temporaryToken = "";
            try {
              const client = await authClient();
              const { data: login, error: loginError } = await client.rpc("student_session_start", {
                p_school_code: "ashiana",
                p_enroll_no: admission,
                p_dob_password: dob
              });
              if (loginError) throw new Error(loginError.message || "Student verification service is unavailable.");
              if (!login?.success || !/^[a-f0-9]{64}$/i.test(String(login.session_token || ""))) {
                throw new Error(login?.message || "Admission No. or DOB is incorrect.");
              }
              temporaryToken = String(login.session_token);
              const deviceSecret = Array.from(crypto.getRandomValues(new Uint8Array(32)), byte => byte.toString(16).padStart(2, "0")).join("");
              const { data: result, error: enrollError } = await client.rpc("student_biometric_enroll", {
                p_session_token: temporaryToken,
                p_device_secret: deviceSecret
              });
              if (enrollError) throw new Error(enrollError.message || "Student fingerprint registration service is unavailable.");
              if (!result?.success) throw new Error(result?.code || "Student fingerprint registration was rejected.");
              try { await window.AshianaNative.enableStudentBiometric(deviceSecret); }
              catch (error) {
                try { await client.rpc("student_biometric_revoke", { p_device_secret: deviceSecret }); } catch (_) {}
                throw error;
              }
              toast("Student fingerprint login is registered on this phone.", "success");
              menu.hidden = true;
              menu.style.setProperty("display", "none", "important");
              trigger.setAttribute("aria-expanded", "false");
              await refresh();
            } catch (error) {
              toast(error.message || "Could not register Student fingerprint.", "error");
              item.disabled = false;
              item.textContent = "Register fingerprint for attendance";
            } finally {
              if (temporaryToken) {
                try {
                  const client = await authClient();
                  await client.rpc("student_session_revoke", { p_token: temporaryToken });
                } catch (_) {}
              }
            }
          }, "bg-violet-50 text-violet-800 border border-violet-200");
        }
      } finally {
        studentFingerprintMenuRefreshInFlight = false;
      }
    };

    // A normal tap performs the useful action immediately: authenticate if
    // this device is enrolled, otherwise register using the live Admission No.
    // and DOB fields. Long-press/context menu keeps the remove action available.
    trigger.setAttribute("aria-label", "Student fingerprint sign-in or registration");
    trigger.removeAttribute("aria-haspopup");
    trigger.onclick = async () => {
      if (trigger.disabled) return;
      trigger.disabled = true;
      try {
        const enrolled = await window.AshianaNative.hasStudentBiometricEnrollment();
        if (enrolled) {
          await authenticateStudentFingerprint();
          return;
        }
        await refresh();
        const registerAction = Array.from(menu.querySelectorAll('[role="menuitem"]'))
          .find(item => /register fingerprint/i.test(item.textContent || ""));
        if (!registerAction) throw new Error("Fingerprint registration is not available. Please try again.");
        registerAction.click();
      } catch (error) {
        toast(error.message || "Student fingerprint action failed.", "error");
      } finally {
        trigger.disabled = false;
      }
    };
    trigger.oncontextmenu = async event => {
      event.preventDefault();
      await refresh();
      const removeAction = Array.from(menu.querySelectorAll('[role="menuitem"]'))
        .find(item => /remove fingerprint/i.test(item.textContent || ""));
      if (!removeAction) return;
      menu.hidden = false;
      menu.style.setProperty("display", "block", "important");
      trigger.setAttribute("aria-expanded", "true");
    };
    document.addEventListener("click", event => {
      if (!form.contains(event.target)) {
        menu.hidden = true;
        menu.style.setProperty("display", "none", "important");
        trigger.setAttribute("aria-expanded", "false");
      }
    });
  }

  function installStudentLoginButton() {
    const form = document.getElementById("student-login-form");
    if (!form || document.getElementById("student-passkey-login")) return;
    const button = document.createElement("button");
    button.id = "student-passkey-login";
    button.type = "button";
    button.textContent = "Sign in with Passkey";
    button.className = "w-full py-3 mt-2 bg-white border border-emerald-800 text-emerald-950 font-bold rounded-xl text-xs";
    button.addEventListener("click", async () => {
      button.disabled = true;
      button.textContent = "Verifying passkey...";
      try {
        await authenticatePasskey("student", "login");
      } catch (error) {
        const message = error.message === "PASSKEY_LOGIN_UNAVAILABLE"
          ? "No usable student passkey was found. Sign in with Admission No. and DOB, then register a passkey again."
          : error.message || "Student passkey sign-in failed.";
        toast(message, "error");
        button.disabled = false;
        button.textContent = "Sign in with Passkey";
      }
    });
    form.append(button);
  }

  // Revoke and erase the Student biometric session before the existing
  // logout handler runs. This prevents a fingerprint from reopening a
  // session that the student has explicitly signed out of.
  let studentLogoutCleanupInProgress = false;
  let studentLogoutReplay = false;
  document.addEventListener("click", async event => {
    if (studentLogoutReplay || studentLogoutCleanupInProgress || currentRole()?.role !== "student") return;
    const control = event.target?.closest?.("button, a, [role='button']");
    if (!control || !/\b(log ?out|sign ?out)\b/i.test(String(control.textContent || control.getAttribute("aria-label") || ""))) return;
    const token = studentSessionToken();
    if (!token) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    studentLogoutCleanupInProgress = true;
    try {
      const client = await authClient();
      // Best-effort server revocation; local and biometric credentials are
      // always erased even if the network is unavailable.
      try { await client.rpc("student_session_revoke", { p_token: token }); }
      catch (error) { console.warn("Student session revocation during logout:", error?.message || error); }
      // Keep the device-bound biometric credential registered. Only the
      // active session is revoked and removed on logout.
      try { await window.AshianaNative?.clearStudentSessionToken?.(); } catch (_) {}
      try { sessionStorage.removeItem(STUDENT_TOKEN_KEY); } catch (_) {}
      try { localStorage.removeItem(STUDENT_TOKEN_KEY); } catch (_) {}
    } finally {
      studentLogoutCleanupInProgress = false;
      studentLogoutReplay = true;
      try { control.click(); } finally { queueMicrotask(() => { studentLogoutReplay = false; }); }
    }
  }, true);

  function watch() {
    installStudentFingerprintLoginControls().catch(error => console.warn("Student fingerprint controls unavailable:", error?.message || error));
    const current = currentRole();
    if (!current) {
      setupPrompted = { admin: false, student: false };
      freshAuthHandled = { admin: false, student: false };
      return;
    }
    offerPasskeySetup(current.role);
  }
  document.addEventListener("DOMContentLoaded", watch);
  new MutationObserver(watch).observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener("storage", watch);
})();
