// TitanFlow Service Worker
// Minimal caching - only cache assets on demand, not on install

const CACHE_NAME = 'titanflow-v2';

// Skip pre-caching on install - assets will be cached on-demand
self.addEventListener('install', (event) => {
    console.log('[SW] Installing - skipping pre-cache for faster startup');
    self.skipWaiting();
});

// Activate event - clean up old caches
self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys()
            .then((cacheNames) => {
                return Promise.all(
                    cacheNames
                        .filter((name) => name !== CACHE_NAME)
                        .map((name) => {
                            console.log('[SW] Removing old cache:', name);
                            return caches.delete(name);
                        })
                );
            })
            .then(() => self.clients.claim())
    );
});

// Fetch event - network first for everything, cache fallback for static assets only
self.addEventListener('fetch', (event) => {
    const url = new URL(event.request.url);

    // Skip non-GET requests
    if (event.request.method !== 'GET') {
        return;
    }

    // Skip API calls, LiveView websockets, and dynamic HTML
    if (
        url.pathname.startsWith('/api') ||
        url.pathname.startsWith('/live') ||
        url.pathname.startsWith('/phoenix') ||
        event.request.headers.get('accept')?.includes('text/html') ||
        url.pathname === '/' ||
        url.pathname.startsWith('/dashboard') ||
        url.pathname.startsWith('/campaigns') ||
        url.pathname.startsWith('/inbox') ||
        url.pathname.startsWith('/numbers') ||
        url.pathname.startsWith('/templates') ||
        url.pathname.startsWith('/settings')
    ) {
        // Always fetch from network for dynamic content
        return;
    }

    // For static assets: try network first, fallback to cache
    if (url.pathname.startsWith('/assets') ||
        url.pathname.startsWith('/images') ||
        url.pathname.startsWith('/fonts') ||
        url.pathname.endsWith('.ico') ||
        url.pathname.endsWith('.png')) {
        event.respondWith(
            fetch(event.request)
                .then((response) => {
                    // Clone and cache the response
                    if (response.ok) {
                        const responseToCache = response.clone();
                        caches.open(CACHE_NAME)
                            .then((cache) => cache.put(event.request, responseToCache));
                    }
                    return response;
                })
                .catch(() => {
                    // Fallback to cache if network fails
                    return caches.match(event.request);
                })
        );
    }
});
