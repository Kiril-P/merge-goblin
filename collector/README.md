# Telemetry collector

A Cloudflare Worker with a D1 table that receives the Goblin's anonymous usage counts
(`lib/telemetry.sh` says exactly what is sent; `src/index.js` drops anything else).

- `POST /v1/events`: open, validated, at most 16 KB and 50 events per request
- `GET /v1/stats?days=N` and `GET /v1/events?since=&limit=`: need `Authorization: Bearer $READ_TOKEN`
- read it with `scripts/fleet-stats.sh`

Deploy: `npx wrangler@4 deploy` (the D1 id is in wrangler.toml; the schema is schema.sql,
applied with `npx wrangler@4 d1 execute merge-goblin-telemetry --remote --file schema.sql`).
Rotate the read token with `wrangler secret put READ_TOKEN` and update the keychain item
`merge-goblin-telemetry` / `read`.
