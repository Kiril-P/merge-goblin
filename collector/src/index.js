// Merge Goblin telemetry collector.
//
//   POST /v1/events            anyone: one event or {events:[...]}, validated, stored
//   GET  /v1/stats?days=30     READ_TOKEN: the aggregates Claude reads to steer the app
//   GET  /v1/events?since=&limit=   READ_TOKEN: raw rows, for anything stats lacks
//   GET  /health
//
// The client (lib/telemetry.sh) already sends only anonymous fields; this re-checks, so
// a buggy or hostile client cannot put a repo name or a paragraph of code in the table.

// The only top-level fields each event may carry. Anything else is dropped unread.
const FIELDS = {
  review: ["status", "provider", "model", "effort", "error", "seconds", "findings", "manual", "focus", "mode"],
  daily: ["settings", "usage", "counts", "quality", "provider", "model", "effort"],
  ui: ["name"],
};
const MAX_BODY = 16 * 1024;
const MAX_BATCH = 50;
const ID = /^[a-f0-9-]{16,40}$/;
const SHORT = /^[A-Za-z0-9._:+\/ -]{0,64}$/;
const KEY = /^[A-Za-z][A-Za-z0-9_.-]{0,47}$/;

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

// Values are numbers, booleans or short safe strings; objects at most two levels deep.
function clean(v, depth = 0) {
  if (typeof v === "number") return Number.isFinite(v) ? Math.max(-1e9, Math.min(1e9, v)) : undefined;
  if (typeof v === "boolean") return v;
  if (typeof v === "string") return SHORT.test(v) ? v : undefined;
  if (v && typeof v === "object" && !Array.isArray(v) && depth < 2) {
    const out = {};
    let n = 0;
    for (const [k, x] of Object.entries(v)) {
      if (!KEY.test(k) || ++n > 120) continue;
      const c = clean(x, depth + 1);
      if (c !== undefined) out[k] = c;
    }
    return out;
  }
  return undefined;
}

function validate(e) {
  if (!e || typeof e !== "object" || e.schema !== 1) return null;
  if (!FIELDS[e.event] || typeof e.id !== "string" || !ID.test(e.id)) return null;
  const { event, id, version, os, arch } = e;
  const rest = Object.fromEntries(FIELDS[event].filter((k) => k in e).map((k) => [k, e[k]]));
  const s = (x) => (typeof x === "string" && SHORT.test(x) ? x.slice(0, 32) : "");
  return { install: id, event, version: s(version), os: s(os), arch: s(arch), data: clean(rest) || {} };
}

async function ingest(req, env) {
  const text = await req.text();
  if (text.length > MAX_BODY) return json({ error: "too large" }, 413);
  let body;
  try { body = JSON.parse(text); } catch { return json({ error: "not json" }, 400); }
  const list = Array.isArray(body?.events) ? body.events.slice(0, MAX_BATCH) : [body];
  const rows = list.map(validate).filter(Boolean);
  if (!rows.length) return json({ error: "nothing valid" }, 400);
  const at = Math.floor(Date.now() / 1000);
  const stmt = env.DB.prepare(
    "INSERT INTO events (at, install, event, version, os, arch, data) VALUES (?, ?, ?, ?, ?, ?, ?)");
  await env.DB.batch(rows.map((r) => stmt.bind(at, r.install, r.event, r.version, r.os, r.arch, JSON.stringify(r.data))));
  return new Response(null, { status: 204 });
}

function authed(req, env) {
  const h = req.headers.get("authorization") || "";
  return env.READ_TOKEN && h === `Bearer ${env.READ_TOKEN}`;
}

async function all(env, sql, ...args) {
  const r = await env.DB.prepare(sql).bind(...args).all();
  return r.results;
}

async function stats(env, days) {
  const since = Math.floor(Date.now() / 1000) - days * 86400;
  const R = "event = 'review' AND at >= ?1";
  const [installs, perDay, versions, byModel, errors, latestDaily, ui] = await Promise.all([
    all(env, "SELECT COUNT(DISTINCT install) AS installs, COUNT(*) AS events FROM events WHERE at >= ?1", since),
    all(env, `SELECT date(at, 'unixepoch') AS day, COUNT(DISTINCT install) AS installs,
                SUM(event = 'review') AS reviews FROM events WHERE at >= ?1 GROUP BY day ORDER BY day`, since),
    all(env, `SELECT version, COUNT(DISTINCT install) AS installs FROM events WHERE at >= ?1
                GROUP BY version ORDER BY installs DESC`, since),
    all(env, `SELECT json_extract(data, '$.provider') AS provider, json_extract(data, '$.model') AS model,
                json_extract(data, '$.effort') AS effort, COUNT(*) AS reviews, COUNT(DISTINCT install) AS installs,
                SUM(json_extract(data, '$.status') = 'posted') AS posted,
                SUM(json_extract(data, '$.status') = 'previewed') AS previewed,
                SUM(json_extract(data, '$.status') = 'failed') AS failed,
                CAST(AVG(json_extract(data, '$.seconds')) AS INTEGER) AS avgSeconds,
                SUM(json_extract(data, '$.findings')) AS findings
              FROM events WHERE ${R} GROUP BY provider, model, effort ORDER BY reviews DESC`, since),
    all(env, `SELECT json_extract(data, '$.provider') AS provider, json_extract(data, '$.error') AS error,
                COUNT(*) AS n FROM events WHERE ${R} AND json_extract(data, '$.status') = 'failed'
              GROUP BY provider, error ORDER BY n DESC`, since),
    // each install's most recent daily snapshot: what it has switched on, what it uses
    all(env, `SELECT e.data FROM events e JOIN (SELECT install, MAX(id) AS id FROM events
                WHERE event = 'daily' AND at >= ?1 GROUP BY install) l ON e.id = l.id`, since),
    all(env, `SELECT json_extract(data, '$.name') AS name, COUNT(*) AS n, COUNT(DISTINCT install) AS installs
              FROM events WHERE event = 'ui' AND at >= ?1 GROUP BY name ORDER BY n DESC`, since),
  ]);

  // Settings adoption and verb usage, summed across installs' latest snapshots.
  const settings = {}, usage = {};
  for (const row of latestDaily) {
    let d; try { d = JSON.parse(row.data); } catch { continue; }
    for (const [k, v] of Object.entries(d.settings || {})) {
      const key = `${k}=${v}`;
      settings[key] = (settings[key] || 0) + 1;
    }
    for (const [k, v] of Object.entries(d.usage || {})) {
      if (typeof v !== "number") continue;
      usage[k] = usage[k] || { uses: 0, installs: 0 };
      usage[k].uses += v; usage[k].installs += v > 0 ? 1 : 0;
    }
  }
  return {
    days, since, installs: installs[0], perDay, versions, byModel, errors,
    snapshots: latestDaily.length, settings, usage, ui,
  };
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (url.pathname === "/health") return json({ ok: true });
    if (url.pathname === "/v1/events" && req.method === "POST") return ingest(req, env);
    if (req.method === "GET" && (url.pathname === "/v1/stats" || url.pathname === "/v1/events")) {
      if (!authed(req, env)) return json({ error: "unauthorized" }, 401);
      if (url.pathname === "/v1/stats") {
        const days = Math.max(1, Math.min(365, parseInt(url.searchParams.get("days") || "30", 10) || 30));
        return json(await stats(env, days));
      }
      const since = parseInt(url.searchParams.get("since") || "0", 10) || 0;
      const limit = Math.max(1, Math.min(5000, parseInt(url.searchParams.get("limit") || "1000", 10) || 1000));
      return json(await all(env, "SELECT * FROM events WHERE at >= ?1 ORDER BY id LIMIT ?2", since, limit));
    }
    return json({ error: "not found" }, 404);
  },
};
