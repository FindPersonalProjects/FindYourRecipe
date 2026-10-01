// Offline support. The site itself is fetched fresh when online (so new deploys show up at once)
// and falls back to the cached copy offline. Recipe data is served from cache and refreshed in the background.
const VERSION = 'fyr-v1';
const SHELL = [
  './', 'index.html', 'css/style.css', 'manifest.webmanifest', 'icons/icon.svg', 'icons/icon-192.png',
  'js/app.js', 'js/store.js', 'js/data.js', 'js/config.js', 'js/cultures.js', 'js/units.js',
  'js/placeholders.js', 'js/share.js', 'js/badges.js', 'data/index.json'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const req = e.request;
  const url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== location.origin) return;   // never touch the database or other sites

  if (url.pathname.includes('/data/')) {
    // stale-while-revalidate for recipe data
    e.respondWith(caches.open(VERSION).then(async cache => {
      const cached = await cache.match(req);
      const fresh = fetch(req).then(res => { if (res.ok) cache.put(req, res.clone()); return res; }).catch(() => cached);
      return cached || fresh;
    }));
    return;
  }

  // network first for the app itself
  e.respondWith(fetch(req)
    .then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(VERSION).then(c => c.put(req, copy)); }
      return res;
    })
    .catch(async () => (await caches.match(req)) || caches.match('index.html')));
});
