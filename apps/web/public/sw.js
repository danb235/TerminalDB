const CACHE = "terminaldb-shell-v11";
const SHELL = ["/", "/manifest.webmanifest", "/terminaldb-icon.svg"];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))),
      ),
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const requestUrl = new URL(event.request.url);
  if (
    event.request.method !== "GET" ||
    requestUrl.origin !== self.location.origin ||
    requestUrl.pathname.startsWith("/api/") ||
    requestUrl.pathname.startsWith("/socket") ||
    requestUrl.pathname.startsWith("/pair/")
  ) {
    return;
  }
  const cacheable =
    requestUrl.pathname === "/" ||
    requestUrl.pathname === "/manifest.webmanifest" ||
    requestUrl.pathname === "/terminaldb-icon.svg" ||
    requestUrl.pathname.startsWith("/assets/");
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        if (cacheable && response.ok && response.type === "basic") {
          const copy = response.clone();
          caches.open(CACHE).then((cache) => cache.put(event.request, copy));
        }
        return response;
      })
      .catch(() => caches.match(event.request).then((response) => response ?? caches.match("/"))),
  );
});
