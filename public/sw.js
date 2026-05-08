// Minimal service worker — its presence is what makes the admin
// installable as a PWA on iOS. Network-first with no aggressive
// caching: admin pages are tenant-scoped and authenticated, so we
// don't want stale data after a deploy.
self.addEventListener("install",  (event) => self.skipWaiting());
self.addEventListener("activate", (event) => self.clients.claim());
self.addEventListener("fetch", (event) => {
  event.respondWith(fetch(event.request).catch(() => caches.match(event.request)));
});
