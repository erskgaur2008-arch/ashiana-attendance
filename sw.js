const CACHE_NAME = "ashiana-attendance-v41";
const APP_SHELL = [
  "./",
  "./index.html",
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
  if (event.request.method !== "GET") return;

  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;

  // Keep HTML/navigation fresh so deployments are picked up promptly.
  if (event.request.mode === "navigate" || url.pathname.endsWith(".html") || url.pathname === "/") {
    event.respondWith(
      (async () => {
        try {
          const preload = await event.preloadResponse;
          const response = preload || await fetch(event.request);
          const copy = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
          return response;
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

  event.respondWith(
    fetch(event.request)
      .then((response) => {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
        return response;
      })
      .catch(() => caches.match(event.request).then((cached) => cached || caches.match("./")))
  );
});
