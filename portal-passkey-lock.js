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
  function ensureControls() {
    const current = currentRole();
    if (!current || document.getElementById("portal-passkey-controls")) return;
    const { role } = current;
    const box = document.createElement("div");
    box.id = "portal-passkey-controls";
    box.style.cssText = "position:fixed;right:12px;bottom:12px;z-index:99990;display:flex;gap:8px;align-items:center;flex-wrap:wrap;justify-content:flex-end;max-width:calc(100vw - 24px)";
    const status = document.createElement("span"); status.id = "portal-passkey-status"; status.hidden = true;
    status.style.cssText = "background:#064e3b;color:#fff;padding:8px 12px;border-radius:10px;font-size:12px;max-width:70vw";
    const enable = document.createElement("button"); enable.type = "button"; enable.textContent = NATIVE() ? "Enable Biometric Lock" : "Enable Passkey";
    enable.style.cssText = "padding:10px 13px;border-radius:12px;background:#064e3b;color:white;border:1px solid #34d399;font-size:12px;font-weight:800;box-shadow:0 4px 16px #0002";
    enable.addEventListener("click", async () => {
      enable.disabled = true;
      try {
        if (NATIVE()) {
          if (!window.AshianaNative?.verifyPortalBiometric) throw new Error("Update the Android app to enable device biometric lock.");
          await window.AshianaNative.verifyPortalBiometric(role);
          setNativeLock(role, true);
          toast("Device biometric lock enabled. It protects this app session on this device.", "success");
        } else {
          if (enable.dataset.hasCredentials === "true") {
            const extra = role === "student" ? { session_token: localStorage.getItem(TOKEN_KEY) || sessionStorage.getItem(TOKEN_KEY) } : {};
            await invoke(role, "enable", extra);
          } else {
            await registerWebPasskey(role);
          }
        }
        enable.textContent = NATIVE() ? "Biometric Lock Enabled" : "Passkey Enabled";
      } catch (e) { toast(e.message || "Could not enable passkey.", "error"); }
      finally { enable.disabled = false; }
    });
    const lock = document.createElement("button"); lock.type = "button"; lock.textContent = "Lock Portal";
    lock.style.cssText = "padding:10px 13px;border-radius:12px;background:white;color:#064e3b;border:1px solid #d1fae5;font-size:12px;font-weight:800;box-shadow:0 4px 16px #0002";
    lock.addEventListener("click", () => {
      if (NATIVE()) {
        if (!nativeLockEnabled(role)) { toast("Enable device biometric lock first.", "error"); return; }
      }
      lockOverlay(role);
    });
    const disable = document.createElement("button"); disable.type = "button"; disable.textContent = "Disable Lock";
    disable.style.cssText = "padding:10px 13px;border-radius:12px;background:#fff1f2;color:#9f1239;border:1px solid #fecdd3;font-size:12px;font-weight:800";
    disable.addEventListener("click", async () => {
      if (!confirm("Disable the passkey/biometric lock for this portal on this account/device?")) return;
      try {
        if (NATIVE()) setNativeLock(role, false);
        else {
          const extra = role === "student" ? { session_token: localStorage.getItem(TOKEN_KEY) || sessionStorage.getItem(TOKEN_KEY) } : {};
          await invoke(role, "disable", extra);
        }
        unlockOverlay(); enable.textContent = NATIVE() ? "Enable Biometric Lock" : "Enable Passkey";
        toast("Portal lock disabled.", "success");
      } catch (e) { toast(e.message || "Could not disable lock.", "error"); }
    });
    box.append(status, enable, lock, disable); document.body.append(box);
    if (!NATIVE()) invoke(role, "status", role === "student" ? { session_token: localStorage.getItem(TOKEN_KEY) || sessionStorage.getItem(TOKEN_KEY) } : {})
      .then(s => {
        enable.dataset.hasCredentials = s.credential_count > 0 ? "true" : "false";
        if (s.enabled) enable.textContent = "Passkey Enabled";
        else if (s.credential_count > 0) enable.textContent = "Re-enable Passkey";
      }).catch(() => {});
  }
  function installStudentLoginButton() {
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
    if (current && NATIVE() && nativeLockEnabled(current.role) && !sessionStorage.getItem("aps_portal_biometric_verified:" + current.role)) {
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
    if (current && NATIVE()) sessionStorage.setItem("aps_portal_biometric_verified:" + current.role, "1");
    originalUnlock();
  };
})();
