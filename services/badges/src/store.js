import { DatabaseSync } from 'node:sqlite';
import { readFileSync, existsSync } from 'node:fs';

const roles = new Set(['member', 'moderator', 'developer', 'supporter']);
const glyphs = new Set(['butterfly', 'heart', 'star', 'sparkle']);
const validNumber = value => /^[1-9][0-9]*$/.test(value) && BigInt(value) < 2n ** 52n;

export function peerKey(value) {
  if (typeof value !== 'string' || value.length > 40) throw new Error('Invalid peer ID');
  if (validNumber(value)) return value;
  const typed = /^(user|bot|group|channel):([1-9][0-9]*)$/.exec(value);
  if (typed && validNumber(typed[2])) return ['user', 'bot'].includes(typed[1]) ? typed[2] : value;
  if (/^-[1-9][0-9]*$/.test(value)) {
    const id = -BigInt(value);
    if (id < 2n ** 52n) {
      const channel = id > 1000000000000n;
      const raw = String(channel ? id - 1000000000000n : id);
      if (validNumber(raw)) return `${channel ? 'channel' : 'group'}:${raw}`;
    }
  }
  throw new Error('Invalid peer ID');
}

export function badgeValue(value) {
  if (!value || !roles.has(value.role) || !glyphs.has(value.glyph)) throw new Error('Invalid badge');
  return { role: value.role, glyph: value.glyph };
}

export class Store {
  constructor(path, legacyPath) {
    this.db = new DatabaseSync(path);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value INTEGER NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS badges (
        peer_id TEXT PRIMARY KEY,
        role TEXT NOT NULL CHECK(role IN ('member','moderator','developer','supporter')),
        glyph TEXT NOT NULL CHECK(glyph IN ('butterfly','heart','star','sparkle')),
        updated_at INTEGER NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS audit (
        id INTEGER PRIMARY KEY, actor TEXT NOT NULL, peer_id TEXT NOT NULL,
        operation TEXT NOT NULL, created_at INTEGER NOT NULL
      ) STRICT;`);
    if (!this.db.prepare('SELECT value FROM metadata WHERE key=?').get('revision')) {
      // Validate the entire old file before writing any migration state.
      let old = { revision: 1, offset: 0, badges: {} };
      if (legacyPath && existsSync(legacyPath)) {
        const raw = readFileSync(legacyPath);
        if (raw.length > 8 * 1024 * 1024) throw new Error('Legacy database too large');
        old = JSON.parse(raw);
      }
      if (!Number.isSafeInteger(old.revision) || old.revision < 1 || !Number.isSafeInteger(old.offset) || old.offset < 0 ||
          !old.badges || typeof old.badges !== 'object' || Array.isArray(old.badges) || Object.keys(old.badges).length > 50000) throw new Error('Invalid legacy database');
      const entries = Object.entries(old.badges).map(([id, badge]) => [peerKey(id), badgeValue(badge)]);
      this.transaction(() => {
        this.db.prepare('INSERT INTO metadata VALUES (?,?)').run('revision', old.revision);
        this.db.prepare('INSERT INTO metadata VALUES (?,?)').run('offset', old.offset);
        const insert = this.db.prepare('INSERT INTO badges VALUES (?,?,?,?)');
        for (const [id, badge] of entries) insert.run(id, badge.role, badge.glyph, Date.now());
      });
    }
  }
  transaction(action) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const value = action(); this.db.exec('COMMIT'); return value; }
    catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  get revision() { return this.db.prepare("SELECT value FROM metadata WHERE key='revision'").get().value; }
  get offset() { return this.db.prepare("SELECT value FROM metadata WHERE key='offset'").get().value; }
  setOffset(value) {
    if (!Number.isSafeInteger(value) || value < 0) throw new Error('Invalid offset');
    this.db.prepare("UPDATE metadata SET value=max(value,?) WHERE key='offset'").run(value);
  }
  get(id) { return this.db.prepare('SELECT role,glyph FROM badges WHERE peer_id=?').get(peerKey(id)) ?? null; }
  list(cursor = '', limit = 100) {
    return this.db.prepare('SELECT peer_id,role,glyph FROM badges WHERE peer_id>? ORDER BY peer_id LIMIT ?').all(cursor, limit);
  }
  catalog(now = Date.now()) {
    const badges = Object.create(null);
    for (const { peer_id, role, glyph } of this.list('', 50000)) badges[peer_id] = { role, glyph };
    return { schema: 3, revision: this.revision, issued: Math.floor(now / 1000), expires: Math.floor(now / 1000) + 86400, badges };
  }
  set(id, badge, actor = 'api') {
    id = peerKey(id);
    if (badge !== null) badge = badgeValue(badge);
    return this.transaction(() => {
      const current = this.get(id);
      if (JSON.stringify(current) === JSON.stringify(badge)) return false;
      if (badge) {
        if (!current && this.db.prepare('SELECT count(*) AS n FROM badges').get().n >= 50000) throw new Error('Catalog full');
        this.db.prepare('INSERT INTO badges VALUES (?,?,?,?) ON CONFLICT(peer_id) DO UPDATE SET role=excluded.role,glyph=excluded.glyph,updated_at=excluded.updated_at').run(id, badge.role, badge.glyph, Date.now());
      } else this.db.prepare('DELETE FROM badges WHERE peer_id=?').run(id);
      this.db.prepare("UPDATE metadata SET value=value+1 WHERE key='revision'").run();
      this.db.prepare('INSERT INTO audit(actor,peer_id,operation,created_at) VALUES (?,?,?,?)').run(actor, id, badge ? 'grant' : 'revoke', Date.now());
      return true;
    });
  }
  close() { this.db.close(); }
}
