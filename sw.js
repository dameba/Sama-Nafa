const CACHE_NAME = "sama-nafa-shell-v1";
const APP_SHELL = ["/", "/manifest.webmanifest", "/icons/sama-nafa.svg"];

// Cache only the app shell. Do not cache Supabase/API requests or personal financial data.
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
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);

  // Keep authentication, database, edge functions, and all cross-origin requests network-only.
  if (request.method !== "GET" || url.origin !== self.location.origin ||
      url.pathname.startsWith("/auth/") || url.pathname.startsWith("/rest/") ||
      url.pathname.startsWith("/functions/")) return;

  // Network-first for navigation so users see the latest app; use shell cache if offline.
  if (request.mode === "navigate") {
    event.respondWith(fetch(request).catch(() => caches.match("/")));
  }
});
