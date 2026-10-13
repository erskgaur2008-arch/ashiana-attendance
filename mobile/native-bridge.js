import { Printer } from "@capgo/capacitor-printer";
import { Directory, Filesystem } from "@capacitor/filesystem";
import { Share } from "@capacitor/share";
import { PushNotifications } from "@capacitor/push-notifications";

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

window.AshianaNative = Object.freeze({
  isAndroid: isNativeAndroid,
  printHtml,
  saveBlob,
  registerPushNotifications,
  requestNotificationPermission
});
