import { timingSafeEqual } from 'node:crypto';
import { peerKey } from './store.js';

function respond(res, status, value, headers = {}) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'X-Content-Type-Options': 'nosniff', ...headers });
  res.end(JSON.stringify(value));
}
async function body(req) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 16384) { const error = new Error('Body too large'); error.status = 413; throw error; }
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}
function authorized(req, key) {
  const supplied = Buffer.from(req.headers.authorization ?? '');
  const expected = Buffer.from(`Bearer ${key}`);
  return supplied.length === expected.length && timingSafeEqual(supplied, expected);
}

export function handler(store, { privateAPI = false, key = '' } = {}) {
  if (privateAPI && key.length < 32) throw new Error('Management API key must be at least 32 characters');
  let cached;
  return async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      if (url.pathname === '/healthz' && req.method === 'GET') return respond(res, 200, { ok: true });
      if (privateAPI) {
        res.setHeader('Cache-Control', 'no-store');
        if (!authorized(req, key)) return respond(res, 401, { error: 'Unauthorized' });
        if (url.pathname === '/private/v1/badges' && req.method === 'GET') {
          const limit = Number(url.searchParams.get('limit') ?? 100);
          if (!Number.isInteger(limit) || limit < 1 || limit > 200) throw new Error('Invalid limit');
          const items = store.list(url.searchParams.get('cursor') ?? '', limit + 1);
          const more = items.length > limit;
          if (more) items.pop();
          return respond(res, 200, { items, next_cursor: more ? items.at(-1).peer_id : null });
        }
        const match = /^\/private\/v1\/badges\/([^/]+)$/.exec(url.pathname);
        if (match) {
          const id = peerKey(decodeURIComponent(match[1]));
          if (req.method === 'GET') return respond(res, 200, { peer_id: id, badge: store.get(id) });
          if (req.method === 'PUT' || req.method === 'DELETE') {
            const badge = req.method === 'PUT' ? await body(req) : null;
            store.set(id, badge);
            return respond(res, 200, { peer_id: id, badge: store.get(id), revision: store.revision });
          }
        }
      } else {
        res.setHeader('Access-Control-Allow-Origin', '*');
        if (req.method === 'OPTIONS' && (url.pathname === '/v3/badges' || url.pathname.startsWith('/v3/badges/'))) {
          res.writeHead(204, { 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type', 'Access-Control-Max-Age': '86400' });
          return res.end();
        }
        if (url.pathname === '/v3/badges' && req.method === 'GET') {
          const now = Date.now();
          if (!cached || cached.revision !== store.revision || now - cached.time >= 60000) {
            cached = { revision: store.revision, time: now, value: store.catalog(now) };
          }
          const etag = `"${cached.revision}-${Math.floor(cached.time / 60000)}"`;
          const headers = { ETag: etag, 'Cache-Control': 'public, max-age=60' };
          if (req.headers['if-none-match'] === etag) { res.writeHead(304, headers); return res.end(); }
          return respond(res, 200, cached.value, headers);
        }
        const match = /^\/v3\/badges\/([^/]+)$/.exec(url.pathname);
        if (match && req.method === 'GET' && match[1] !== 'lookup') {
          const id = peerKey(decodeURIComponent(match[1]));
          return respond(res, 200, { peer_id: id, badge: store.get(id) }, { 'Cache-Control': 'public, max-age=60' });
        }
        if (url.pathname === '/v3/badges/lookup' && req.method === 'POST') {
          const { peer_ids } = await body(req);
          if (!Array.isArray(peer_ids) || peer_ids.length > 200) throw new Error('Expected up to 200 peer_ids');
          const badges = Object.create(null);
          for (const id of peer_ids) { const key = peerKey(id); badges[key] = store.get(key); }
          return respond(res, 200, { badges });
        }
      }
      respond(res, 404, { error: 'Not found' });
    } catch (error) {
      const status = error.status ?? (error instanceof SyntaxError || /^(Invalid |Expected )/.test(error.message) ? 400 : 500);
      if (status === 500) console.error('API request failed');
      if (!res.headersSent) respond(res, status, { error: status === 413 ? 'Body too large' : status === 500 ? 'Service unavailable' : 'Invalid request' });
      else res.end();
    }
  };
}
