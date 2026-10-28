/* Admin + Student passkey lock UI. Server-side role checks remain authoritative. */
(() => {
  "use strict";
  const FN = "portal-passkeys";
  const NATIVE = () => Boolean(window.AshianaNative?.isAndroid?.());
  const TOKEN_KEY = "aps_student_session_token_v1";
  const LOCK_KEY = "aps_portal_passkey_lock_v1";
  const b64uToBytes = value => {
    const s = String(value || "").replace(/-/g, "+").replace(/_/g, "/");
    const raw = atob(s + "=".repeat((4 - s.length % 4) % 4));
    return Uint8Array.from(raw, c => c.charCodeAt(0));
  };
  const bytesToB64u = value => {
    const bytes = new Uint8Array(value); let raw = "";
    for (let i = 0; i < bytes.length; i += 8192) raw += String.fromCharCode(...bytes.subarray(i, i + 8192));
    return btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
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
    const response = credential.response;
    const result = {
      id: credential.id, rawId: bytesToB64u(credential.rawId), type: credential.type,
      authenticatorAttachment: credential.authenticatorAttachment || undefined,
      clientExtensionResults: credential.getClientExtensionResults(),
      response: {}
    };
    if (response.attestationObject) {
      result.response.attestationObject = bytesToB64u(response.attestationObject);
      result.response.clientDataJSON = bytesToB64u(response.clientDataJSON);
      result.response.transports = response.getTransports ? response.getTransports() : [];
    } else {
      result.response.authenticatorData = bytesToB64u(response.authenticatorData);
      result.response.clientDataJSON = bytesToB64u(response.clientDataJSON);
      result.response.signature = bytesToB64u(response.signature);
      if (response.userHandle) result.response.userHandle = bytesToB64u(response.userHandle);
    }
    return result;
  };
  async function client() {
    if (window.__ashianaMainSupabaseClient) return window.__ashianaMainSupabaseClient;
    if (!window.supabase?.createClient) throw new Error("Authentication service is not ready. Please try again.");
    window.__ashianaMainSupabaseClient = window.supabase.createClient(
      "https://oalfzgluqroqbbrulhpr.supabase.co",
      "sb_publishable_PND9f9FKbNrxlEakSgLKYA_5EsqLHkg",
      { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } }
    );
    return window.__ashianaMainSupabaseClient;
  }
  async function invoke(role, action, extra = {}) {
    const supa = await client();
    const { data, error } = await supa.functions.invoke(FN, { body: { role, action, ...extra } });
    if (error) throw new Error(data?.error || error.message || "Passkey request failed.");
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
  function nativeLockEnabled(role) {
    try { return localStorage.getItem(LOCK_KEY + ":" + role) === "enabled"; } catch (_) { return false; }
  }
  function setNativeLock(role, enabled) {
    try { localStorage.setItem(LOCK_KEY + ":" + role, enabled ? "enabled" : "disabled"); } catch (_) {}
  }
  function toast(message, kind = "info") {
    if (typeof window.showToast === "function") { window.showToast(message, kind); return; }
    const el = document.getElementById("portal-passkey-status");
    if (el) { el.textContent = message; el.hidden = false; }
    else alert(message);
  }
  async function registerWebPasskey(role) {
    const extra = {};
    if (role === "student") {
      const token = localStorage.getItem(TOKEN_KEY) || sessionStorage.getItem(TOKEN_KEY);
      if (!token) throw new Error("Sign in with Admission No. and DOB first, then register a passkey.");
      extra.session_token = token;
    }
    const { options } = await invoke(role, "registration-options", extra);
    const credential = await navigator.credentials.create({ publicKey: publicKeyOptions(options) });
    if (!credential) throw new Error("Passkey registration was cancelled.");
    const payload = await credentialJSON(credential);
    const result = await invoke(role, "registration-verify", { ...extra, credential: payload });
    if (!result.success) throw new Error("Passkey registration could not be completed.");
    toast("Passkey enabled for this " + role + " account.", "success");
    return true;
  }
  async function authenticateWebPasskey(role, purpose = "unlock") {
    const extra = {};
    if (role === "student") {
      if (purpose === "unlock") {
        const token = localStorage.getItem(TOKEN_KEY) || sessionStorage.getItem(TOKEN_KEY);
        if (!token) throw new Error("Student session expired. Sign in again with Admission No. and DOB.");
        extra.session_token = token;
      } else {
        const input = document.getElementById("student-login-admission");
        const admission = String(input?.value || "").trim();
        if (!admission) throw new Error("Enter your Admission No. first.");
        extra.admission_no = admission;
      }
    }
    const { options } = await invoke(role, "authentication-options", extra);
    const credential = await navigator.credentials.get({ publicKey: publicKeyOptions(options) });
    if (!credential) throw new Error("Passkey verification was cancelled.");
    const result = await invoke(role, "authentication-verify", { ...extra, credential: await credentialJSON(credential) });
    if (!result.success) throw new Error("Passkey verification failed.");
    if (role === "student" && result.session_token) {
      const token = String(result.session_token);
      if (!/^[a-f0-9]{64}$/i.test(token)) throw new Error("Student session token is invalid.");
      localStorage.setItem(TOKEN_KEY, token);
      sessionStorage.setItem(TOKEN_KEY, token);
      // Reuse the established secure session-restoration path.
      location.reload();
      return true;
    }
    if (purpose === "unlock") unlockOverlay();
    return true;
  }
  let overlay = null;
  const webPasskeyEnabled = { admin: false, student: false };
  const nativeVerified = { admin: false, student: false };
  let idleTimer = null;
  function armIdleLock(role) {
    clearTimeout(idleTimer);
    if (!role || (NATIVE() ? !nativeLockEnabled(role) : !webPasskeyEnabled[role])) return;
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
    if (overlay) return;
    overlay = document.createElement("div");
    overlay.id = "portal-passkey-lock-overlay";
    overlay.style.cssText = "position:fixed;inset:0;z-index:2147483000;background:rgba(2,20,15,.97);display:flex;align-items:center;justify-content:center;padding:24px;color:white;font-family:system-ui,sans-serif";
    const card = document.createElement("div");
    card.style.cssText = "width:min(100%,380px);background:#064e3b;border:1px solid #34d399;border-radius:24px;padding:28px;text-align:center;box-shadow:0 24px 80px #0008";
    const title = document.createElement("h2"); title.textContent = "Portal locked"; title.style.cssText = "font-size:24px;font-weight:800;margin:0 0 8px";
    const desc = document.createElement("p"); desc.textContent = "Verify your identity to continue."; desc.style.cssText = "font-size:14px;opacity:.9;margin:0 0 22px";
    const btn = document.createElement("button"); btn.type = "button"; btn.textContent = "Unlock with Passkey"; btn.style.cssText = "width:100%;padding:14px;border-radius:12px;background:white;color:#064e3b;font-weight:800";
    btn.addEventListener("click", async () => {
      btn.disabled = true; btn.textContent = "Verifying…";
      try {
        if (NATIVE()) {
          await window.AshianaNative.verifyPortalBiometric(role);
          unlockOverlay();
        } else await authenticateWebPasskey(role, "unlock");
      } catch (e) { toast(e.message || "Verification failed.", "error"); btn.disabled = false; btn.textContent = "Unlock with Passkey"; }
    });
    card.append(title, desc, btn); overlay.append(card); document.body.append(overlay);
  }
  function unlockOverlay() { overlay?.remove(); overlay = null; }
  let setupPrompted = { admin: false, student: false };
  async function offerAutomaticSetup(role) {
    if (!role || setupPrompted[role]) return;
    setupPrompted[role] = true;
    if (NATIVE()) {
      if (nativeLockEnabled(role)) return;
      if (!(await window.AshianaNative?.portalBiometricAvailable?.())) {
        toast("To use fingerprint sign-in, first add a fingerprint or face unlock in Android Settings.", "info");
        return;
      }
      const dialog = document.createElement("div");
      dialog.id = "portal-biometric-setup-prompt";
      dialog.style.cssText = "position:fixed;inset:0;z-index:2147483001;background:rgba(2,20,15,.78);display:flex;align-items:center;justify-content:center;padding:24px;font-family:system-ui,sans-serif";
      dialog.innerHTML = '<section style="width:min(100%,380px);background:white;border-radius:22px;padding:24px;text-align:center;color:#064e3b"><div style="font-size:38px" aria-hidden="true">👆</div><h2 style="font-size:22px;font-weight:800;margin:8px 0">Enable fingerprint sign-in</h2><p style="font-size:14px;margin:0 0 20px">Use your device fingerprint or face unlock for this ' + (role === "admin" ? "Admin" : "Student") + ' account on this phone.</p><button type="button" data-biometric-setup="enable" style="width:100%;padding:13px;border-radius:12px;background:#064e3b;color:white;font-weight:800">Continue with biometrics</button><button type="button" data-biometric-setup="later" style="width:100%;padding:12px;margin-top:8px;color:#475569;font-weight:700">Not now</button></section>';
      dialog.addEventListener("click", async event => {
        const choice = event.target.closest("[data-biometric-setup]");
        if (!choice) return;
        if (choice.dataset.biometricSetup === "later") { dialog.remove(); return; }
        choice.disabled = true;
        try {
          await window.AshianaNative.verifyPortalBiometric(role);
          setNativeLock(role, true);
          nativeVerified[role] = true;
          toast("Biometric verification enabled for this " + role + " portal on this device.", "success");
          dialog.remove();
        } catch (error) {
          toast(error.message || "Biometric setup was cancelled.", "error");
          choice.disabled = false;
        }
      });
      document.body.append(dialog);
      return;
    }
    try {
      const extra = role === "student" ? { session_token: localStorage.getItem(TOKEN_KEY) || sessionStorage.getItem(TOKEN_KEY) } : {};
      const status = await invoke(role, "status", extra);
      webPasskeyEnabled[role] = Boolean(status.enabled);
      if (status.credential_count > 0) return;
      const dialog = document.createElement("div");
      dialog.id = "portal-biometric-setup-prompt";
      dialog.style.cssText = "position:fixed;inset:0;z-index:2147483001;background:rgba(2,20,15,.78);display:flex;align-items:center;justify-content:center;padding:24px;font-family:system-ui,sans-serif";
      dialog.innerHTML = '<section style="width:min(100%,380px);background:white;border-radius:22px;padding:24px;text-align:center;color:#064e3b"><div style="font-size:38px" aria-hidden="true">🔐</div><h2 style="font-size:22px;font-weight:800;margin:8px 0">Set up passkey sign-in</h2><p style="font-size:14px;margin:0 0 20px">Use your device screen lock or available biometric method for this account.</p><button type="button" data-passkey-setup="enable" style="width:100%;padding:13px;border-radius:12px;background:#064e3b;color:white;font-weight:800">Set up passkey</button><button type="button" data-passkey-setup="later" style="width:100%;padding:12px;margin-top:8px;color:#475569;font-weight:700">Not now</button></section>';
      dialog.addEventListener("click", async event => {
        const choice = event.target.closest("[data-passkey-setup]");
        if (!choice) return;
        if (choice.dataset.passkeySetup === "later") { dialog.remove(); return; }
        choice.disabled = true;
        try { await registerWebPasskey(role); webPasskeyEnabled[role] = true; dialog.remove(); }
        catch (error) { toast(error.message || "Passkey setup failed.", "error"); choice.disabled = false; }
      });
      document.body.append(dialog);
    } catch (error) { console.warn("Could not check portal passkey status:", error); }
  }
  function ensureControls() {
    const current = currentRole();
    if (!current) { setupPrompted = { admin: false, student: false }; return; }
    offerAutomaticSetup(current.role);
  }
  function installStudentLoginButton() {
    // Native APK currently uses the secure device-biometric session lock; true
    // cross-platform server-backed passkey login requires Android Credential Manager.
    if (NATIVE()) return;
    const form = document.getElementById("student-login-form");
    if (!form || document.getElementById("student-passkey-login")) return;
    const button = document.createElement("button");
    button.id = "student-passkey-login"; button.type = "button"; button.textContent = "Sign in with Passkey";
    button.className = "w-full py-3 mt-2 bg-white border border-emerald-800 text-emerald-950 font-bold rounded-xl text-xs";
    button.addEventListener("click", async () => {
      button.disabled = true; button.textContent = "Verifying passkey…";
      try {
        if (NATIVE()) throw new Error("Passkey sign-in is not available in this Android build yet. Use Admission No. and DOB; device biometric lock is available after sign-in.");
        await authenticateWebPasskey("student", "login");
      } catch (e) { toast(e.message || "Passkey sign-in failed.", "error"); }
      finally { button.disabled = false; button.textContent = "Sign in with Passkey"; }
    });
    form.append(button);
  }
  function watch() {
    installStudentLoginButton();
    ensureControls();
    const current = currentRole();
    if (current && NATIVE() && nativeLockEnabled(current.role) && !nativeVerified[current.role]) {
      // Do not silently unlock after a page reload when the user enabled device lock.
      lockOverlay(current.role);
    }
  }
  document.addEventListener("DOMContentLoaded", watch);
  new MutationObserver(() => watch()).observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener("storage", watch);
  // Prevent a successful native biometric unlock from immediately re-locking on observer runs.
  const originalUnlock = unlockOverlay;
  unlockOverlay = function() {
    const current = currentRole();
    if (current && NATIVE()) nativeVerified[current.role] = true;
    originalUnlock();
  };
})();
