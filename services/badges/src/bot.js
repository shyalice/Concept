import { setTimeout as delay } from 'node:timers/promises';
import { peerKey, badgeValue } from './store.js';

export function parseAdmins(value) {
  const ids = (value ?? '').split(',').map(id => id.trim());
  if (!ids.length || ids.some(id => !/^[1-9][0-9]*$/.test(id) || !Number.isSafeInteger(Number(id)))) throw new Error('Invalid BOT_ADMIN_IDS');
  return new Set(ids);
}

export async function command(message, admins, api) {
  if (!message || message.chat?.type !== 'private' || message.chat.id !== message.from?.id) return '';
  const words = (message.text ?? '').trim().split(/\s+/);
  const name = words[0].split('@')[0];
  const user = String(message.from.id);
  if (name === '/start' || name === '/whoami') return `Your Telegram ID: ${user}\n/get [PEER_ID]`;
  if (name !== '/get' && !admins.has(user)) return 'Administrator access required.';
  try {
    if (name === '/get') {
      if (words.length > 2) return 'Usage: /get [PEER_ID]';
      const id = peerKey(words[1] ?? user);
      const { badge } = await api('GET', `/private/v1/badges/${encodeURIComponent(id)}`);
      return badge ? `${id}: ${badge.role} / ${badge.glyph}` : 'No Concept badge assigned.';
    }
    if (name === '/grant') {
      if (words.length < 3 || words.length > 4) return 'Usage: /grant PEER_ID member|moderator|developer|supporter [butterfly|heart|star|sparkle]';
      const id = peerKey(words[1]);
      const badge = badgeValue({ role: words[2], glyph: words[3] ?? 'butterfly' });
      await api('PUT', `/private/v1/badges/${encodeURIComponent(id)}`, badge);
      return `Assigned ${id}: ${badge.role} / ${badge.glyph}`;
    }
    if (name === '/revoke') {
      if (words.length !== 2) return 'Usage: /revoke PEER_ID';
      const id = peerKey(words[1]);
      await api('DELETE', `/private/v1/badges/${encodeURIComponent(id)}`);
      return `Revoked badge for ${id}`;
    }
    if (name === '/list') {
      if (words.length > 2) return 'Usage: /list [cursor]';
      const { items, next_cursor } = await api('GET', `/private/v1/badges?limit=30&cursor=${encodeURIComponent(words[1] ?? '')}`);
      return (items.map(item => `${item.peer_id}: ${item.role} / ${item.glyph}`).join('\n') || 'No badges assigned.') + (next_cursor ? `\nNext: /list ${next_cursor}` : '');
    }
    return 'Commands: /get, /grant, /revoke, /list, /whoami. Peer IDs: USER_ID, bot:ID, group:ID, channel:ID or -100…';
  } catch {
    return 'Invalid peer ID or badge, or service temporarily unavailable.';
  }
}

export async function runBot({ token, admins, store, apiOrigin, apiKey, signal }) {
  const api = async (method, path, body) => {
    const response = await fetch(new URL(path, apiOrigin), {
      method, headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.any([signal, AbortSignal.timeout(10000)])
    });
    if (!response.ok) throw new Error('Management API unavailable');
    return response.json();
  };
  const telegram = async (method, value) => {
    const response = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(value),
      signal: AbortSignal.any([signal, AbortSignal.timeout(35000)])
    });
    const result = await response.json();
    if (!response.ok || !result.ok) throw new Error('Telegram API unavailable');
    return result.result;
  };
  while (!signal.aborted) {
    try {
      const updates = await telegram('getUpdates', { offset: store.offset, timeout: 25, allowed_updates: ['message'] });
      for (const update of updates) {
        if (signal.aborted) break;
        if (!Number.isSafeInteger(update.update_id) || update.update_id < store.offset) continue;
        const reply = await command(update.message, admins, api);
        if (reply) await telegram('sendMessage', { chat_id: update.message.chat.id, text: reply });
        store.setOffset(update.update_id + 1);
      }
    } catch {
      if (signal.aborted) break;
      // Do not log fetch exceptions: their URL can contain the bot credential.
      console.error('Bot request failed; retrying');
      await delay(3000, undefined, { signal }).catch(() => {});
    }
  }
}
