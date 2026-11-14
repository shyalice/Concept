import { createServer } from 'node:http';
import { mkdirSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';
import { Store } from './store.js';
import { handler } from './api.js';
import { runBot, parseAdmins } from './bot.js';

process.umask(0o077);
const path = process.env.BADGE_DB ?? '/var/lib/concept-badges/badges.sqlite';
mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
const key = process.env.MANAGEMENT_API_KEY ?? '';
if (key.length < 32) throw new Error('Set MANAGEMENT_API_KEY to a random secret of at least 32 characters');
const admins = process.env.BOT_TOKEN ? parseAdmins(process.env.BOT_ADMIN_IDS) : null;
const store = new Store(path, process.env.LEGACY_BADGE_DB);
chmodSync(path, 0o600);
function listen(port, privateAPI) {
  const server = createServer({ requestTimeout: 15000, headersTimeout: 10000, keepAliveTimeout: 5000, maxHeaderSize: 16384 }, handler(store, { privateAPI, key }));
  server.maxRequestsPerSocket = 100;
  server.listen(port, '127.0.0.1');
  return server;
}
const publicPort = Number(process.env.PORT ?? 8087);
const privatePort = Number(process.env.MANAGEMENT_PORT ?? 8088);
const publicServer = listen(publicPort, false);
const privateServer = listen(privatePort, true);
const controller = new AbortController();
const bot = admins ? runBot({ token: process.env.BOT_TOKEN, admins, store, apiOrigin: `http://127.0.0.1:${privatePort}`, apiKey: key, signal: controller.signal }) : Promise.resolve();
let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  controller.abort();
  await Promise.all([bot, ...[publicServer, privateServer].map(server => new Promise(resolve => server.close(resolve)))]);
  store.close();
}
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
