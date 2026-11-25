import { Printer } from "@capgo/capacitor-printer";
import { Directory, Filesystem } from "@capacitor/filesystem";
import { Share } from "@capacitor/share";
import { PushNotifications } from "@capacitor/push-notifications";
import { LocalNotifications } from "@capacitor/local-notifications";
import { NativeBiometric, AccessControl } from "@capgo/capacitor-native-biometric";
import { CapacitorPasskey } from "@capgo/capacitor-passkey";
import { SecureStorage } from "@aparajita/capacitor-secure-storage";
import { Geolocation } from "@capacitor/geolocation";
import { App } from "@capacitor/app";

function isNativeAndroid() {
  return Boolean(window.Capacitor?.isNativePlatform?.() && window.Capacitor?.getPlatform?.() === "android");
}

let nativePasskeyInitError = null;
const nativePasskeyInit = isNativeAndroid()
  ? CapacitorPasskey.autoShimWebAuthn().catch(error => {
      nativePasskeyInitError = error;
      console.error("Android passkey initialization failed:", error?.message || error);
    })
  : Promise.resolve();

async function ensurePasskeyReady() {
  if (!isNativeAndroid()) return true;
  await nativePasskeyInit;
  if (nativePasskeyInitError) throw new Error("Android passkeys could not be initialized. Update the app and try again.");
  const support = await CapacitorPasskey.isSupported();
  if (!support?.available) throw new Error("This Android device has no passkey provider available. Set up Google Password Manager or another passkey provider first.");
  return true;
}

async function passkeySupported() {
  if (!isNativeAndroid()) return Boolean(navigator.credentials?.create && navigator.credentials?.get);
  try { await ensurePasskeyReady(); return true; } catch (_) { return false; }
}

async function printHtml(html, name = "Ashiana Attendance") {
  if (!isNativeAndroid()) throw new Error("Native printing is available only in the Android app.");
  await Printer.printHtml({ name, html });
}

async function saveBlob(blob, fileName, mimeType = "application/octet-stream") {
  if (!isNativeAndroid()) throw new Error("Native file sharing is available only in the Android app.");
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let binary = "";
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  const base64 = btoa(binary);
  const safeName = String(fileName || "ashiana-file").replace(/[^a-zA-Z0-9._-]+/g, "-");
  const result = await Filesystem.writeFile({
    path: safeName,
    data: base64,
    directory: Directory.Cache,
    recursive: true
  });
  await Share.share({
    title: safeName,
    dialogTitle: "Save or share " + safeName,
    files: [result.uri]
  });
}

async function getCurrentPosition(options = {}) {
  if (!isNativeAndroid()) throw new Error("Native GPS location is available only in the Android app.");
  let permission = await Geolocation.checkPermissions();
  if (permission.location !== "granted") {
    permission = await Geolocation.requestPermissions({ permissions: ["location"] });
  }
  if (permission.location !== "granted") {
    throw new Error("Location permission is required to mark staff attendance.");
  }
  return await Geolocation.getCurrentPosition({
    enableHighAccuracy: true,
    timeout: 15000,
    maximumAge: 0,
    ...options
  });
}

async function requestNotificationPermission() {
  if (!isNativeAndroid()) return false;
  const permission = await PushNotifications.checkPermissions();
  const result = permission.receive === "granted" ? permission : await PushNotifications.requestPermissions();
  return result.receive === "granted";
}

let pushListenersRegistered = false;

function getRegisteredPushToken() {
  try { return String(window.localStorage.getItem("aps_student_fcm_device_token_v1") || "").trim(); }
  catch (_) { return ""; }
}

async function registerPushNotifications() {
  if (!isNativeAndroid()) throw new Error("Native push notifications are available only in the Android app.");
  const permission = await PushNotifications.checkPermissions();
  const result = permission.receive === "granted" ? permission : await PushNotifications.requestPermissions();
  if (result.receive !== "granted") throw new Error("Notification permission was not granted.");

  const localPermission = await LocalNotifications.checkPermissions();
  const localResult = localPermission.display === "granted" ? localPermission : await LocalNotifications.requestPermissions();
  if (localResult.display !== "granted") throw new Error("Android display notification permission was not granted.");

  await LocalNotifications.createChannel({
    id: "school_updates",
    name: "School Updates",
    description: "School notices and student updates",
    importance: 4,
    sound: "default",
    vibration: true
  });

  // Capacitor/FCM does not automatically show a tray notification for a push
  // received while the app is foregrounded. Surface it locally and to the UI.
  if (!pushListenersRegistered) {
    await PushNotifications.addListener("pushNotificationReceived", async notification => {
      const title = String(notification?.title || "Ashiana Public School").slice(0, 120);
      const body = String(notification?.body || "").slice(0, 500);
      const data = notification?.data || {};
      window.dispatchEvent(new CustomEvent("ashiana:push-received", {
        detail: { title, body, category: data.category || "school_notice", data }
      }));
      if (!body) return;
      try {
        await LocalNotifications.schedule({
          notifications: [{
            id: Math.floor(Date.now() % 2147483647),
            title,
            body,
            channelId: "school_updates",
            // Foreground push alerts do not need exact timing. Keeping them
            // inexact avoids Android's separate Alarms & reminders access screen.
            schedule: { at: new Date(Date.now() + 250) },
            isExactNotification: false,
            extra: { category: String(data.category || "school_notice"), url: String(data.url || "/") }
          }]
        });
      } catch (error) {
        console.warn("Could not display foreground push notification:", error?.message || error);
      }
    });
    pushListenersRegistered = true;
  }

  return await new Promise(async (resolve, reject) => {
    let settled = false;
    let registrationListener = null;
    let registrationErrorListener = null;
    const cleanup = () => {
      clearTimeout(timeout);
      try { registrationListener?.remove(); } catch (_) {}
      try { registrationErrorListener?.remove(); } catch (_) {}
    };
    const timeout = setTimeout(() => {
      if (!settled) {
        settled = true;
        cleanup();
        reject(new Error("Timed out waiting for a Firebase device token. Check Firebase Android configuration."));
      }
    }, 20000);
    try {
      registrationListener = await PushNotifications.addListener("registration", token => {
        if (settled) return;
        settled = true;
        cleanup();
        try { window.localStorage.setItem("aps_student_fcm_device_token_v1", String(token.value || "")); } catch (_) {}
        resolve(token.value);
      });
      registrationErrorListener = await PushNotifications.addListener("registrationError", error => {
        if (settled) return;
        settled = true;
        cleanup();
        reject(new Error(error?.error || "Push registration failed."));
      });
      await PushNotifications.register();
    } catch (error) {
      if (!settled) {
        settled = true;
        cleanup();
        reject(error);
      }
    }
  });
}


const STUDENT_SESSION_STORAGE_KEY = "session_token";
const STUDENT_SESSION_STORAGE_PREFIX = "ashiana_student_session_v2_";
const STUDENT_LEGACY_CREDENTIAL_CLEANUP_KEY = "aps_student_legacy_credential_cleanup_v1";

async function cleanupLegacyStudentCredentialsOnce() {
  if (!isNativeAndroid()) return;
  try {
    if (window.localStorage.getItem(STUDENT_LEGACY_CREDENTIAL_CLEANUP_KEY) === "done") return;
  } catch (_) {}
  try {
    await SecureStorage.setKeyPrefix("ashiana_student_session_v1_");
    await SecureStorage.remove("credentials");
    try { window.localStorage.setItem(STUDENT_LEGACY_CREDENTIAL_CLEANUP_KEY, "done"); } catch (_) {}
  } catch (error) {
    console.warn("Legacy Student credential cleanup was deferred:", error?.message || error);
  }
}

async function setStudentSessionStoragePrefix() {
  await SecureStorage.setKeyPrefix(STUDENT_SESSION_STORAGE_PREFIX);
}

async function saveStudentSessionToken(token) {
  if (!isNativeAndroid()) throw new Error("Secure student session storage is available only in the Android app.");
  const value = String(token || "").trim();
  if (!/^[a-f0-9]{64}$/i.test(value)) throw new Error("Student session token is invalid.");
  await cleanupLegacyStudentCredentialsOnce();
  await setStudentSessionStoragePrefix();
  await SecureStorage.set(STUDENT_SESSION_STORAGE_KEY, value);
  return true;
}

async function getStudentSessionToken() {
  if (!isNativeAndroid()) return null;
  await cleanupLegacyStudentCredentialsOnce();
  await setStudentSessionStoragePrefix();
  const stored = await SecureStorage.get(STUDENT_SESSION_STORAGE_KEY);
  const token = typeof stored === "string" ? stored.trim() : "";
  if (!/^[a-f0-9]{64}$/i.test(token)) {
    if (stored) await SecureStorage.remove(STUDENT_SESSION_STORAGE_KEY);
    return null;
  }
  return token;
}

async function clearStudentSessionToken() {
  if (!isNativeAndroid()) return false;
  await cleanupLegacyStudentCredentialsOnce();
  await setStudentSessionStoragePrefix();
  await SecureStorage.remove(STUDENT_SESSION_STORAGE_KEY);
  return true;
}

const STUDENT_BIOMETRIC_SERVER = "com.ashiana.attendance.student.session.v1";

async function studentBiometricAvailable() {
  if (!isNativeAndroid()) return false;
  try {
    const result = await NativeBiometric.isAvailable({ useFallback: false });
    return Boolean(result?.isAvailable);
  } catch (_) { return false; }
}

async function hasStudentBiometricEnrollment() {
  if (!isNativeAndroid()) return false;
  try {
    const result = await NativeBiometric.isCredentialsSaved({ server: STUDENT_BIOMETRIC_SERVER });
    return Boolean(result?.isSaved);
  } catch (_) { return false; }
}

async function enableStudentBiometric(deviceSecret) {
  if (!isNativeAndroid()) throw new Error("Fingerprint login is available only in the Android app.");
  const secret = String(deviceSecret || "").trim();
  if (!/^[a-f0-9]{64}$/i.test(secret)) throw new Error("Student device credential is invalid.");
  if (!(await studentBiometricAvailable())) throw new Error("No enrolled fingerprint is available. Set up a fingerprint in Android Settings first.");
  await NativeBiometric.setCredentials({
    username: "student-device",
    password: secret,
    server: STUDENT_BIOMETRIC_SERVER,
    accessControl: AccessControl.BIOMETRY_CURRENT_SET,
    description: "Unlock Ashiana Student login with your enrolled fingerprint"
  });
  return true;
}

async function getStudentBiometricSessionToken() {
  if (!isNativeAndroid()) throw new Error("Fingerprint login is available only in the Android app.");
  const saved = await NativeBiometric.isCredentialsSaved({ server: STUDENT_BIOMETRIC_SERVER });
  if (!saved?.isSaved) throw new Error("Fingerprint login is not enabled. Sign in with Admission No. and DOB first.");
  const credentials = await NativeBiometric.getSecureCredentials({
    server: STUDENT_BIOMETRIC_SERVER,
    reason: "Verify your identity to sign in to Ashiana Student Portal",
    title: "Student fingerprint verification",
    subtitle: "Ashiana Public School",
    description: "Use the fingerprint enrolled on this phone",
    negativeButtonText: "Cancel",
    maxAttempts: 3
  });
  const token = String(credentials?.password || "").trim();
  if (!/^[a-f0-9]{64}$/i.test(token)) throw new Error("Saved Student device credential is invalid. Sign in with Admission No. and DOB again.");
  return token;
}

async function disableStudentBiometric() {
  if (!isNativeAndroid()) return false;
  try { await NativeBiometric.deleteCredentials({ server: STUDENT_BIOMETRIC_SERVER }); } catch (_) {}
  return true;
}

const STAFF_BIOMETRIC_POINTER_KEY = "aps_staff_biometric_staff_id_v1";
const STAFF_BIOMETRIC_SERVER_PREFIX = "com.ashiana.attendance.staff.";

function staffBiometricServer(staffId) {
  const id = String(staffId ?? "").trim();
  if (!id || id.length > 256) throw new Error("Invalid staff account for biometric enrollment.");

  // Preserve existing server keys for conventional UUID/database IDs. Some
  // valid staff records use prefixes/underscores, so encode those safely
  // instead of rejecting them and preventing biometric registration.
  if (/^[a-zA-Z0-9-]{8,128}$/.test(id)) return STAFF_BIOMETRIC_SERVER_PREFIX + id;
  const bytes = new TextEncoder().encode(id);
  const encoded = Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
  return STAFF_BIOMETRIC_SERVER_PREFIX + "x" + encoded;
}

async function staffBiometricAvailable() {
  if (!isNativeAndroid()) return false;
  try {
    const result = await NativeBiometric.isAvailable({ useFallback: false });
    return Boolean(result?.isAvailable);
  } catch (_) { return false; }
}

async function hasStaffBiometricEnrollment(forStaffId) {
  if (!isNativeAndroid()) return false;
  const staffId = String(forStaffId || window.localStorage.getItem(STAFF_BIOMETRIC_POINTER_KEY) || "");
  if (!staffId) return false;
  try {
    const result = await NativeBiometric.isCredentialsSaved({ server: staffBiometricServer(staffId) });
    return Boolean(result?.isSaved);
  } catch (_) { return false; }
}

async function prepareStaffBiometricAccount(staffId) {
  if (!isNativeAndroid()) return false;
  const nextId = String(staffId || "").trim();
  if (!nextId) return false;
  const currentId = window.localStorage.getItem(STAFF_BIOMETRIC_POINTER_KEY);
  if (currentId && currentId !== nextId) {
    try { await NativeBiometric.deleteCredentials({ server: staffBiometricServer(currentId) }); } catch (_) {}
    window.localStorage.removeItem(STAFF_BIOMETRIC_POINTER_KEY);
  }
  return true;
}

async function enableStaffBiometric({ staffId, loginId, pin }) {
  if (!isNativeAndroid()) throw new Error("Fingerprint login is available only in the Android app.");
  if (!/^\d{4}$/.test(String(pin || ""))) throw new Error("Sign in with your current 4-digit PIN before enabling fingerprint login.");
  const server = staffBiometricServer(staffId);
  const available = await staffBiometricAvailable();
  if (!available) throw new Error("No enrolled device biometric is available. Set up a fingerprint in Android Settings first.");
  await NativeBiometric.setCredentials({
    username: String(loginId || "").trim(),
    password: String(pin),
    server,
    accessControl: AccessControl.BIOMETRY_CURRENT_SET,
    description: "Unlock Ashiana staff sign-in with your enrolled fingerprint",
    negativeButtonText: "Cancel"
  });
  window.localStorage.setItem(STAFF_BIOMETRIC_POINTER_KEY, String(staffId));
  return true;
}

async function getStaffBiometricCredentials() {
  if (!isNativeAndroid()) throw new Error("Fingerprint login is available only in the Android app.");
  const staffId = window.localStorage.getItem(STAFF_BIOMETRIC_POINTER_KEY);
  if (!staffId) throw new Error("Fingerprint login is not enabled on this device. Sign in with your PIN first.");
  const server = staffBiometricServer(staffId);
  const saved = await NativeBiometric.isCredentialsSaved({ server });
  if (!saved?.isSaved) {
    window.localStorage.removeItem(STAFF_BIOMETRIC_POINTER_KEY);
    throw new Error("Fingerprint login is no longer enrolled. Sign in with your PIN to set it up again.");
  }
  try {
    const credentials = await NativeBiometric.getSecureCredentials({
      server,
      reason: "Verify your identity to sign in to Ashiana Attendance",
      title: "Staff fingerprint verification",
      subtitle: "Ashiana Public School",
      description: "Use the fingerprint enrolled on this phone",
      negativeButtonText: "Use PIN",
      maxAttempts: 3
    });
    if (!credentials?.username || !/^\d{4}$/.test(String(credentials.password || ""))) {
      throw new Error("Saved fingerprint credentials are invalid. Please sign in with your PIN.");
    }
    return { staffId, loginId: credentials.username, pin: credentials.password };
  } catch (error) {
    const message = String(error?.message || "");
    if (/key invalid|invalidated|not found|no credentials|biometric.*changed/i.test(message)) {
      try { await NativeBiometric.deleteCredentials({ server }); } catch (_) {}
      window.localStorage.removeItem(STAFF_BIOMETRIC_POINTER_KEY);
    }
    throw error;
  }
}

async function disableStaffBiometric() {
  if (!isNativeAndroid()) return false;
  const staffId = window.localStorage.getItem(STAFF_BIOMETRIC_POINTER_KEY);
  if (staffId) {
    try { await NativeBiometric.deleteCredentials({ server: staffBiometricServer(staffId) }); } catch (_) {}
  }
  window.localStorage.removeItem(STAFF_BIOMETRIC_POINTER_KEY);
  return true;
}

// Handle Android hardware Back inside the web app instead of letting Capacitor
// immediately terminate the activity. The page decides which view/modal to close.
if (isNativeAndroid()) {
  App.addListener("backButton", () => {
    window.dispatchEvent(new CustomEvent("ashiana:native-back"));
  }).catch(error => console.warn("Android Back handler registration failed:", error));
}

// Register native FCM tokens for authenticated Staff/Admin accounts. Student
// subscriptions use the separate revocable-session flow in the Student portal.
const STAFF_ADMIN_AUTH_KEY = "sb-oalfzgluqroqbbrulhpr-auth-token";
const PUSH_FUNCTION_URL = "https://oalfzgluqroqbbrulhpr.supabase.co/functions/v1/push-notifications";
const PUSH_ANON_KEY = "sb_publishable_PND9f9FKbNrxlEakSgLKYA_5EsqLHkg";
let staffPushRegistrationInFlight = false;
async function registerStaffPushForSession() {
  if (!isNativeAndroid() || staffPushRegistrationInFlight) return false;
  let accessToken = "";
  try {
    const auth = JSON.parse(window.localStorage.getItem(STAFF_ADMIN_AUTH_KEY) || "null");
    accessToken = String(auth?.access_token || "");
  } catch (_) {}
  if (!accessToken) return false;
  staffPushRegistrationInFlight = true;
  try {
    const deviceToken = await registerPushNotifications();
    if (!deviceToken) throw new Error("Firebase did not return a device token.");
    const response = await fetch(PUSH_FUNCTION_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: PUSH_ANON_KEY,
        Authorization: "Bearer " + accessToken
      },
      body: JSON.stringify({ action: "subscribe", platform: "android", deviceToken })
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(result.error || "Staff push subscription could not be saved.");
    return true;
  } catch (error) {
    console.warn("Staff/Admin push registration failed:", error?.message || error);
    return false;
  } finally {
    staffPushRegistrationInFlight = false;
  }
}

// Auth storage is written in the same tab, so periodically detect a completed
// Staff/Admin sign-in. No student session token is read or persisted here.
if (isNativeAndroid()) {
  let lastStaffAuthToken = "";
  window.setInterval(() => {
    let current = "";
    try {
      const auth = JSON.parse(window.localStorage.getItem(STAFF_ADMIN_AUTH_KEY) || "null");
      current = String(auth?.access_token || "");
    } catch (_) {}
    if (current && current !== lastStaffAuthToken) {
      lastStaffAuthToken = current;
      registerStaffPushForSession().catch(error => console.warn("Staff push registration:", error?.message || error));
    }
    if (!current) lastStaffAuthToken = "";
  }, 8000);
}

window.AshianaNative = Object.freeze({
  isAndroid: isNativeAndroid,
  getCurrentPosition,
  printHtml,
  saveBlob,
  registerPushNotifications,
  getRegisteredPushToken,
  requestNotificationPermission,
  ensurePasskeyReady,
  passkeySupported,
  staffBiometricAvailable,
  hasStaffBiometricEnrollment,
  enableStaffBiometric,
  prepareStaffBiometricAccount,
  getStaffBiometricCredentials,
  disableStaffBiometric,
  saveStudentSessionToken,
  getStudentSessionToken,
  clearStudentSessionToken,
  studentBiometricAvailable,
  hasStudentBiometricEnrollment,
  enableStudentBiometric,
  getStudentBiometricSessionToken,
  disableStudentBiometric
});
