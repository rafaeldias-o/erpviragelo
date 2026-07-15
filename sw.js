// ViraGelo ERP — Service Worker
// Estratégia:
// - HTML/estáticos do próprio site (mesma origem): cache com fallback pra rede (funciona offline básico).
// - Chamadas ao Supabase e a CDNs externos (supabase-js, fontes): sempre vão direto pra rede — nunca cacheadas,
//   porque são dados ao vivo (estoque, pedidos, financeiro) e não podem ficar desatualizados.
// - Versão do cache abaixo: mude o número sempre que publicar uma atualização. Isso invalida o cache antigo
//   automaticamente e dispara o aviso de "nova versão disponível" no app, sem quebrar a sessão de quem já está usando.

const CACHE_VERSION = 'viragelo-v1';
const STATIC_ASSETS = [
  './index.html',
  './manifest.json',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-maskable-512.png',
  './icons/apple-touch-icon.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) => cache.addAll(STATIC_ASSETS))
  );
  // não chama skipWaiting() automaticamente — só quando o usuário confirmar a atualização (ver mensagem 'skipWaiting' abaixo),
  // pra não trocar a versão embaixo dos pés de alguém no meio de uma operação.
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_VERSION).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('message', (event) => {
  if (event.data === 'skipWaiting') self.skipWaiting();
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  const isSameOrigin = url.origin === self.location.origin;

  // Fora da mesma origem (Supabase, CDN de fontes/scripts): sempre rede, nunca intercepta.
  if (!isSameOrigin) return;

  // Navegação (abrir/recarregar o app): tenta a rede primeiro pra sempre pegar a versão mais nova;
  // se estiver offline, cai pro que tiver em cache (offline básico).
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request).catch(() => caches.match('./index.html'))
    );
    return;
  }

  // Estáticos da mesma origem (ícones, manifest): cache primeiro, com atualização em segundo plano.
  event.respondWith(
    caches.match(event.request).then((cached) => {
      const network = fetch(event.request).then((resp) => {
        if (resp && resp.ok) {
          caches.open(CACHE_VERSION).then((cache) => cache.put(event.request, resp.clone()));
        }
        return resp;
      }).catch(() => cached);
      return cached || network;
    })
  );
});
