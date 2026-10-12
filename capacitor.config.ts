import type { CapacitorConfig } from "@capacitor/cli";

const role = (process.env.APP_ROLE || "all").toLowerCase();
const variants: Record<string, { appId: string; appName: string }> = {
  admin: { appId: "com.ashianapublicschool.attendance.admin", appName: "Ashiana Admin" },
  staff: { appId: "com.ashianapublicschool.attendance.staff", appName: "Ashiana Staff" },
  student: { appId: "com.ashianapublicschool.attendance.student", appName: "Ashiana Student" },
  all: { appId: "com.ashianapublicschool.attendance", appName: "Ashiana Attendance" }
};
const selected = variants[role] || variants.all;

const config: CapacitorConfig = {
  appId: selected.appId,
  appName: selected.appName,
  webDir: "mobile/www",
  android: { backgroundColor: "#064E3B" }
};

export default config;
