import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { Store, peerKey } from '../src/store.js';
import { handler } from '../src/api.js';
import { command } from '../src/bot.js';

test('peer namespaces, Bot API IDs and invalid identifiers', () => {
  for (const [value, expected] of [['17', '17'], ['bot:17', '17'], ['user:17', '17'], ['-17', 'group:17'], ['-1000000000017', 'channel:17'], ['channel:17', 'channel:17']]) assert.equal(peerKey(value), expected);
  for (const id of ['0', '01', '-0', 'group:0', '__proto__', '1e5', '4503599627370496', '', null]) assert.throws(() => peerKey(id));
});

test('legacy import survives reopen, keeps offset and is idempotent', () => {
  const dir = mkdtempSync(join(tmpdir(), 'concept-badges-'));
  try {
    const legacy = join(dir, 'old.json');
    const path = join(dir, 'db.sqlite');
    writeFileSync(legacy, JSON.stringify({ revision: 6, offset: 197, badges: { '17': { role: 'member', glyph: 'butterfly' }, 'group:17': { role: 'moderator', glyph: 'star' } } }));
    let store = new Store(path, legacy);
    assert.equal(store.revision, 6); assert.equal(store.offset, 197);
    store.set('channel:17', { role: 'supporter', glyph: 'heart' });
    assert.equal(store.revision, 7);
    store.set('channel:17', { role: 'supporter', glyph: 'heart' });
    assert.equal(store.revision, 7);
    store.close(); store = new Store(path, legacy);
    assert.equal(store.revision, 7); assert.equal(store.list().length, 3);
    assert.equal(store.offset, 197);
    assert.throws(() => store.set('17', { role: 'admin', glyph: 'star' }));
    assert.equal(store.get('17').role, 'member');
    store.close();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('public API cannot manage badges; private API requires token; caching and batch lookups', async t => {
  const store = new Store(':memory:');
  const key = 'x'.repeat(48);
  const servers = [createServer(handler(store)), createServer(handler(store, { privateAPI: true, key }))];
  const origins = [];
  for (const server of servers) { server.listen(0, '127.0.0.1'); await once(server, 'listening'); origins.push(`http://127.0.0.1:${server.address().port}`); }
  t.after(async () => { await Promise.all(servers.map(server => new Promise(resolve => server.close(resolve)))); store.close(); });
  assert.equal((await fetch(`${origins[0]}/private/v1/badges/17`, { method: 'PUT' })).status, 404);
  assert.equal((await fetch(`${origins[1]}/private/v1/badges/17`)).status, 401);
  const preflight = await fetch(`${origins[0]}/v3/badges/lookup`, { method: 'OPTIONS' });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get('Access-Control-Allow-Origin'), '*');
  assert.equal((await fetch(`${origins[1]}/private/v1/badges`, { method: 'OPTIONS' })).status, 401);
  const response = await fetch(`${origins[1]}/private/v1/badges/group:17`, { method: 'PUT', headers: { Authorization: `Bearer ${key}` }, body: JSON.stringify({ role: 'member', glyph: 'butterfly' }) });
  assert.equal(response.status, 200);
  const catalog = await fetch(`${origins[0]}/v3/badges`);
  const etag = catalog.headers.get('etag');
  assert.equal((await catalog.json()).badges['group:17'].role, 'member');
  assert.equal((await fetch(`${origins[0]}/v3/badges`, { headers: { 'If-None-Match': etag } })).status, 304);
  const batch = await fetch(`${origins[0]}/v3/badges/lookup`, { method: 'POST', body: JSON.stringify({ peer_ids: ['17', 'group:17'] }) });
  const { badges } = await batch.json(); assert.equal(badges['17'], null); assert.equal(badges['group:17'].role, 'member');
  const invalid = await fetch(`${origins[1]}/private/v1/badges/17`, { method: 'PUT', headers: { Authorization: `Bearer ${key}` }, body: '{invalid' });
  assert.equal(invalid.status, 400); assert.equal(store.get('17'), null);
});

test('bot ACL rejects group commands and unauthorized grants before calling management API', async () => {
  let calls = 0;
  const api = async () => { calls++; return {}; };
  const message = { chat: { type: 'private', id: 17 }, from: { id: 17 }, text: '/grant 19 moderator' };
  assert.match(await command(message, new Set(['18']), api), /Administrator/);
  assert.equal(calls, 0);
  assert.equal(await command({ ...message, chat: { type: 'group', id: -17 } }, new Set(['17']), api), '');
  assert.equal(calls, 0);
  assert.match(await command(message, new Set(['17']), api), /Assigned 19/); assert.equal(calls, 1);
});
