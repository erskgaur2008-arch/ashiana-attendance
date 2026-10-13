import { Printer } from "@capgo/capacitor-printer";
import { Directory, Filesystem } from "@capacitor/filesystem";
import { Share } from "@capacitor/share";
import { PushNotifications } from "@capacitor/push-notifications";
import { NativeBiometric, AccessControl } from "@capgo/capacitor-native-biometric";

function isNativeAndroid() {
  return Boolean(window.Capacitor?.isNativePlatform?.() && window.Capacitor?.getPlatform?.() === "android");
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

async function requestNotificationPermission() {
  if (!isNativeAndroid()) return false;
  const permission = await PushNotifications.checkPermissions();
  const result = permission.receive === "granted" ? permission : await PushNotifications.requestPermissions();
  return result.receive === "granted";
}

async function registerPushNotifications() {
  if (!isNativeAndroid()) throw new Error("Native push notifications are available only in the Android app.");
  const permission = await PushNotifications.checkPermissions();
  const result = permission.receive === "granted" ? permission : await PushNotifications.requestPermissions();
  if (result.receive !== "granted") throw new Error("Notification permission was not granted.");
  return await new Promise(async (resolve, reject) => {
    let settled = false;
    const timeout = setTimeout(() => {
      if (!settled) { settled = true; reject(new Error("Timed out waiting for a Firebase device token. Check Firebase Android configuration.")); }
    }, 20000);
    await PushNotifications.addListener("registration", token => {
      if (settled) return;
      settled = true; clearTimeout(timeout); resolve(token.value);
    });
    await PushNotifications.addListener("registrationError", error => {
      if (settled) return;
      settled = true; clearTimeout(timeout); reject(new Error(error?.error || "Push registration failed."));
    });
    try { await PushNotifications.register(); }
    catch (error) { if (!settled) { settled = true; clearTimeout(timeout); reject(error); } }
  });
}


const STAFF_BIOMETRIC_POINTER_KEY = "aps_staff_biometric_staff_id_v1";
const STAFF_BIOMETRIC_SERVER_PREFIX = "com.ashiana.attendance.staff.";

function staffBiometricServer(staffId) {
  const id = String(staffId || "").trim();
  if (!id || !/^[a-zA-Z0-9-]{8,128}$/.test(id)) throw new Error("Invalid staff account for biometric enrollment.");
  return STAFF_BIOMETRIC_SERVER_PREFIX + id;
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

window.AshianaNative = Object.freeze({
  isAndroid: isNativeAndroid,
  printHtml,
  saveBlob,
  registerPushNotifications,
  requestNotificationPermission,
  staffBiometricAvailable,
  hasStaffBiometricEnrollment,
  enableStaffBiometric,
  getStaffBiometricCredentials,
  disableStaffBiometric
});
