const CACHE_NAME = "ashiana-attendance-v56";
const APP_SHELL = [
  "./",
  "./index.html",
  "./portal-passkey-lock.js",
  "./event-photo-gallery.js",
  "./dark-mode.css?v=3",
  "./dark-mode.js?v=3",
  "./role-permissions.js?v=1",
  "./manifest.webmanifest",
  "./logo 2.png"
];

function isStaticAsset(request) {
  const url = new URL(request.url);
  return /\.(?:js|css|png|jpg|jpeg|webp|svg|ico|woff2?)$/i.test(url.pathname);
}

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))
      ))
      .then(() => {
        if ("navigationPreload" in self.registration) {
          return self.registration.navigationPreload.enable();
        }
      })
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);

  // Never put authenticated API, session, or RPC responses in Cache Storage.
  // Supabase is currently cross-origin, but keep this explicit so a future
  // same-origin proxy or deployment change cannot accidentally cache them.
  const isSupabaseHost = url.hostname === "supabase.co" || url.hostname.endsWith(".supabase.co");
  const isSensitiveApiPath = /\/(?:auth\/v1|rest\/v1|functions\/v1|realtime\/v1|storage\/v1)\//i.test(url.pathname);
  if (isSupabaseHost || isSensitiveApiPath) return;

  if (event.request.method !== "GET") return;
  if (url.origin !== self.location.origin) return;

  // Keep HTML/navigation fresh so deployments are picked up promptly.
  if (event.request.mode === "navigate" || url.pathname.endsWith(".html") || url.pathname === "/") {
    event.respondWith(
      (async () => {
        try {
          const preload = await event.preloadResponse;
          const response = preload || await fetch(event.request);
          // Add the shared theme assets for older or alternate app HTML builds.
          // The primary page includes them directly; avoid duplicate resources.
          let page = response;
          const contentType = response && response.headers.get("content-type") || "";
          if (response && response.ok && contentType.includes("text/html")) {
            const html = await response.clone().text();
            const hasThemeCss = /<link\b[^>]*\bhref=["'][^"']*dark-mode\.css(?:\?[^"']*)?["'][^>]*>/i.test(html);
            const hasThemeJs = /<script\b[^>]*\bsrc=["'][^"']*dark-mode\.js(?:\?[^"']*)?["'][^>]*>/i.test(html);
            const hasRolePermissions = /<script\b[^>]*\bsrc=["'][^"']*role-permissions\.js(?:\?[^"']*)?["'][^>]*>/i.test(html);
            let withTheme = html;
            if (!hasThemeCss) {
              withTheme = withTheme.replace(/<\/head>/i, '<link rel="stylesheet" href="./dark-mode.css?v=3"></head>');
            }
            if (!hasThemeJs) {
              withTheme = withTheme.replace(/<\/body>/i, '<script src="./dark-mode.js?v=3" defer></script></body>');
            }
            if (!hasRolePermissions) {
              withTheme = withTheme.replace(/<\/body>/i, '<script src="./role-permissions.js?v=1" defer></script></body>');
            }
            if (withTheme !== html) {
              const headers = new Headers(response.headers);
              headers.delete("content-length");
              page = new Response(withTheme, { status: response.status, statusText: response.statusText, headers });
            }
          }
          // Only cache good responses (never a 404/500 error page).
          if (page && page.ok && page.type === "basic") {
            const copy = page.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
          }
          return page;
        } catch (_) {
          return caches.match(event.request).then((cached) => cached || caches.match("./"));
        }
      })()
    );
    return;
  }

  // Vendor scripts and other static assets are cache-first after the first load.
  // This avoids repeated network downloads while still allowing the HTML to
  // control application updates.
  if (isStaticAsset(event.request)) {
    event.respondWith(
      caches.match(event.request).then((cached) => {
        if (cached) return cached;
        return fetch(event.request).then((response) => {
          if (response.ok) {
            const copy = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
          }
          return response;
        });
      })
    );
    return;
  }

  // Unknown same-origin GET requests are network-only. Do not cache arbitrary
  // responses: a future API route could return private student/staff data.
  // Only the explicit app shell, navigations, and known static assets above
  // are eligible for Cache Storage.
});


// Display Web Push notifications. The service worker does not trust payload URLs.
self.addEventListener("push", (event) => {
  let payload = {};
  try { payload = event.data ? event.data.json() : {}; } catch (_) {}
  const title = String(payload.title || "Ashiana Public School").slice(0, 120);
  const body = String(payload.body || "You have a new school update.").slice(0, 500);
  const category = String(payload.category || "school_notice");
  const allowed = ["school_notice", "leave_status", "homework_timetable", "attendance_update"];
  const safeCategory = allowed.includes(category) ? category : "school_notice";
  event.waitUntil(self.registration.showNotification(title, {
    body,
    icon: "./logo%202.png",
    badge: "./logo%202.png",
    tag: String(payload.tag || safeCategory).slice(0, 120),
    data: { category: safeCategory },
    renotify: false
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = new URL("./", self.registration.scope).href;
  event.waitUntil((async () => {
    const clients = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const client of clients) {
      if (client.url.startsWith(self.registration.scope) && "focus" in client) {
        await client.focus();
        return;
      }
    }
    if (self.clients.openWindow) await self.clients.openWindow(target);
  })());
});
