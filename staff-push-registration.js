/* Staff/Admin Web Push registration for the Ashiana PWA. */
(() => {
  "use strict";
  if (!("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) return;
  if (window.Capacitor?.isNativePlatform?.()) return; // Native FCM registration is handled separately.
  const SUPABASE_URL = "https://oalfzgluqroqbbrulhpr.supabase.co";
  const ANON_KEY = "sb_publishable_PND9f9FKbNrxlEakSgLKYA_5EsqLHkg";
  const AUTH_KEY = "sb-oalfzgluqroqbbrulhpr-auth-token";
  const decode = value => {
    const raw = atob(String(value).replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - String(value).length % 4) % 4));
    return Uint8Array.from(raw, c => c.charCodeAt(0));
  };
  const session = () => {
    try {
      const value = JSON.parse(localStorage.getItem(AUTH_KEY) || "null");
      return String(value?.access_token || "");
    } catch (_) { return ""; }
  };
  let button;
  function showEnableButton() {
    if (button || Notification.permission !== "default") return;
    button = document.createElement("button");
    button.type = "button";
    button.textContent = "Enable Message Notifications";
    button.setAttribute("aria-label", "Enable school message push notifications");
    button.style.cssText = "position:fixed;z-index:2147483000;right:16px;bottom:18px;padding:12px 16px;border:0;border-radius:12px;background:#065f46;color:#fff;font:600 14px system-ui;box-shadow:0 4px 18px #0003";
    button.addEventListener("click", async () => {
      button.disabled = true;
      button.textContent = "Enabling notifications…";
      try {
        const permission = await Notification.requestPermission();
        if (permission !== "granted") throw new Error("Notification permission was not granted.");
        await register();
        button.remove();
        button = null;
      } catch (error) {
        button.textContent = "Retry Message Notifications";
        button.disabled = false;
        console.warn("Staff push registration:", error?.message || error);
      }
    });
    document.body.append(button);
  }
  async function register() {
    const token = session();
    if (!token) return;
    const configResponse = await fetch(SUPABASE_URL + "/functions/v1/push-notifications", {
      method: "POST", headers: { "Content-Type": "application/json", apikey: ANON_KEY },
      body: JSON.stringify({ action: "config" })
    });
    if (!configResponse.ok) throw new Error("Push configuration could not be loaded.");
    const config = await configResponse.json();
    if (!config.vapidPublicKey || !config.webPushConfigured) throw new Error("Web Push is not configured on the server.");
    const registration = await navigator.serviceWorker.ready;
    let subscription = await registration.pushManager.getSubscription();
    if (!subscription) {
      subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: decode(config.vapidPublicKey)
      });
    }
    const response = await fetch(SUPABASE_URL + "/functions/v1/push-notifications", {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: ANON_KEY, Authorization: "Bearer " + token },
      body: JSON.stringify({ action: "subscribe", platform: "web", subscription })
    });
    if (!response.ok) {
      const result = await response.json().catch(() => ({}));
      throw new Error(result.error || "Staff push subscription could not be saved.");
    }
    window.dispatchEvent(new CustomEvent("ashiana:staff-push-registered"));
  }
  async function check() {
    if (!session()) {
      if (button) { button.remove(); button = null; }
      return;
    }
    if (Notification.permission === "granted") {
      try { await register(); } catch (error) { console.warn("Staff push registration:", error?.message || error); }
    } else if (Notification.permission === "default") showEnableButton();
  }
  document.addEventListener("DOMContentLoaded", check);
  window.addEventListener("storage", check);
  // Supabase auth persists in the same tab, where the storage event does not fire.
  window.setInterval(check, 8000);
})();
