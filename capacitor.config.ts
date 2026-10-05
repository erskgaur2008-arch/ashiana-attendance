import type { CapacitorConfig } from "@capacitor/cli";

const config: CapacitorConfig = {
  appId: "com.ashianapublicschool.attendance",
  appName: "Ashiana Attendance",
  webDir: "mobile/www",
  server: {
    url: "https://erskgaur2008-arch.github.io/ashiana-attendance/",
    cleartext: false
  },
  android: {
    backgroundColor: "#064E3B"
  }
};

export default config;
