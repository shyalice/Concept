# Concept badge API

Node.js 24+ with built-in SQLite. No runtime npm dependencies, signing keys or notification relay.
Run `npm test`, then `npm start`. See `deploy/concept-badges.env.example`.
Both listeners bind to loopback: publish 8087 through HTTPS nginx/Cloudflare; 8088 is private and
must never be proxied publicly. Private requests require `Authorization: Bearer MANAGEMENT_API_KEY`.
Generate the key with `openssl rand -hex 32`; keep the environment file mode 0600.

## API

- `GET /v3/badges`: catalog with schema/revision/issued/expires/badges; ETag/304 supported.
- `GET /v3/badges/{peer}`: `{peer_id,badge}`, with null for an unassigned peer.
- `POST /v3/badges/lookup`: `{peer_ids:["123","group:123"]}`, up to 200 peers.
- Private `GET /private/v1/badges?limit=100&cursor=...`: `{items,next_cursor}`.
- Private `GET|PUT|DELETE /private/v1/badges/{peer}`: lookup/grant/revoke.
  PUT body: `{"role":"member","glyph":"butterfly"}`.

Roles: member/moderator/developer/supporter. Glyphs: butterfly/heart/star/sparkle.
Users/bots share numeric IDs; groups use group:N; channels/supergroups use channel:N.
Management also accepts Bot API negative IDs and user:N/bot:N aliases.
The app fetches one shared catalog and resolves badges in memory. Its User-Agent is cuteangelgirl/1.0;
this is not an authentication credential. The current app uses only unsigned v3 HTTPS catalogs.

## Bot and storage

Set BOT_TOKEN and comma-separated BOT_ADMIN_IDS. The bot uses the private HTTP API. Grants/revokes/list
require an allowed user in their own private chat. Commands: `/grant PEER_ID ROLE [GLYPH]`,
`/revoke PEER_ID`, `/get [PEER_ID]`, `/list [cursor]`, `/whoami`.
SQLite stores badges, revision, bot update offset and a management audit trail. Writes are prepared,
idempotent and transactional. No Telegram login sessions or message contents are stored.

## Migration

Back up service, environment and state first. Stop the old service before starting the new bot.
Set LEGACY_BADGE_DB to the old JSON file. The first start validates/imports all records, revision and
offset transactionally; later starts retain SQLite and ignore the old file. The old file stays intact.
Use `deploy/concept-badges.service`, state directory owned by concept-badges, mode 0700.
For live backups use SQLite's backup API; copying only the main database while writing omits the WAL.
The supplied nginx configurations never expose the private management listener. The Flexible example
preserves the existing Cloudflare HTTP origin; do not add HTTP→HTTPS origin redirects in Flexible mode.

## Cloudflare

A UA alone does not bypass Under Attack. Add `deploy/cloudflare-skip-rule.json` to the zone's
http_request_firewall_custom entrypoint ruleset. It skips Security Level only for the public badge API
and this UA. Other WAF rules and management authentication remain active. See
[Cloudflare skip options](https://developers.cloudflare.com/waf/custom-rules/skip/options/).
No zone credentials are included, and the rule is not installed automatically.
