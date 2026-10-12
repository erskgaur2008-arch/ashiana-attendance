import { Printer } from "@capgo/capacitor-printer";
import { Directory, Filesystem } from "@capacitor/filesystem";
import { Share } from "@capacitor/share";

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

window.AshianaNative = Object.freeze({
  isAndroid: isNativeAndroid,
  printHtml,
  saveBlob
});
