#!/usr/bin/env bash
#
# scripts/demo-home.sh <dir> — a sandbox GOBLIN_HOME full of plausible state.
#
# For looking at the app without touching your real reviews: point the app at it with
#   GOBLIN_HOME=<dir> "Merge Goblin.app/Contents/MacOS/GoblinBar"
# It is also what the screenshot run (`GoblinBar --snapshot <out>`) renders from.
# Nothing in it is real; no GitHub call is ever made against it.
# Prints the id of the review that is waiting to be read.

set -euo pipefail
DIR="${1:?usage: demo-home.sh <dir>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$DIR/demo-sleeper.pid" ]; then kill "$(cat "$DIR/demo-sleeper.pid")" 2>/dev/null || true; fi
rm -rf "$DIR"; mkdir -p "$DIR/jobs"
NOW="$(date +%s)"
# The signed-in gh account, so the demo does not show a "wrong account" warning.
LOGIN="$(awk '/^github\.com:/{f=1; next} /^[^[:space:]]/{f=0} f && $1=="user:"{print $2; exit}' "$HOME/.config/gh/hosts.yml" 2>/dev/null)"
[ -n "$LOGIN" ] || LOGIN=ada

cat > "$DIR/config.json" <<JSON
{"schemaVersion":2,"identity":{"githubLogin":"$LOGIN"},"enabled":true,"provider":"claude",
 "providers":{"claude":{"model":"sonnet","bin":""},"codex":{"model":"","bin":""},"cursor":{"model":"composer-2.5","bin":""}},
 "repos":[{"slug":"acme/widgets","enabled":true},{"slug":"acme/billing-api","enabled":true},{"slug":"acme/mobile","enabled":false}],
 "fleet":["grace","linus"],"setupComplete":true,"lastRepo":"acme/widgets","maxReviewsPerDay":20}
JSON

cat > "$DIR/inbox.json" <<JSON
{"schemaVersion":1,"at":$NOW,"stale":false,"counts":{"waiting":3,"mine":3},"prs":[
 {"repo":"acme/widgets","number":2461,"title":"Retry failed webhook deliveries with exponential backoff","url":"https://github.com/acme/widgets/pull/2461","author":"grace","state":"waiting"},
 {"repo":"acme/billing-api","number":873,"title":"Fix proration when a plan changes mid-cycle","url":"https://github.com/acme/billing-api/pull/873","author":"linus","state":"waiting"},
 {"repo":"acme/widgets","number":2458,"title":"Move the settings screen onto the new design tokens","url":"https://github.com/acme/widgets/pull/2458","author":"margaret","state":"waiting"}]}
JSON

ev() { jq -nc --argjson at "$1" --argjson n "$2" --arg t "$3" --arg repo "$4" --argjson c "$5" --arg st "$6" --arg r "$7" \
  '{at:$at, number:$n, title:$t, url:("https://github.com/"+$repo+"/pull/"+($n|tostring)), costUsd:$c, status:$st, reason:$r, repo:$repo, provider:"claude", model:"sonnet"}'; }
{
  ev $((NOW-86000)) 2440 "Add CSV export to the reports page" acme/widgets 0.31 posted ""
  ev $((NOW-52000)) 2447 "Stop double-charging on retried checkouts" acme/billing-api 0.44 posted ""
  ev $((NOW-9000))  2452 "Bump the image pipeline to Node 22" acme/widgets 0 failed "timeout"
  ev $((NOW-3600))  2455 "Cache the feature-flag lookup per request" acme/widgets 0.27 posted ""
} > "$DIR/events.jsonl"

mkjob() { # id repo number title phase created extra-json
  mkdir -p "$DIR/jobs/$1"
  jq -n --arg id "$1" --arg repo "$2" --argjson n "$3" --arg t "$4" --arg ph "$5" --argjson at "$6" --argjson extra "$7" \
    '{id:$id, repo:$repo, number:$n, title:$t, url:("https://github.com/"+$repo+"/pull/"+($n|tostring)),
      phase:$ph, mode:"preview", provider:"", model:"", focus:"full", force:false,
      createdAt:$at, updatedAt:$at, providerUsed:"claude", author:"grace"} + $extra' > "$DIR/jobs/$1/job.json"
}

# running right now — with a live pid, so it is not reconciled to "interrupted"
sleep 3600 & SLEEPER=$!; echo "$SLEEPER" > "$DIR/demo-sleeper.pid"
mkjob "j$((NOW-90))-11111" acme/widgets 2461 "Retry failed webhook deliveries with exponential backoff" reviewing $((NOW-90)) "{\"pid\":$SLEEPER}"

# waiting to be read, with a real preview on disk
READY="j$((NOW-600))-22222"
mkjob "$READY" acme/billing-api 873 "Fix proration when a plan changes mid-cycle" ready $((NOW-600)) \
  '{"pid":1,"author":"linus","result":{"counts":"🔴 1 blocker · 🟠 1 convention · ⚪ 1 nit","findings":3,"costUsd":0.38},"head":"9f3c2a1"}'
mkdir -p "$DIR/jobs/$READY/preview"
cat > "$DIR/jobs/$READY/preview/review.json" <<'JSON'
{"slug":"acme/billing-api","pr":873,"head":"9f3c2a1d0e","base":"main","title":"Fix proration when a plan changes mid-cycle",
 "url":"https://github.com/acme/billing-api/pull/873","provider":"claude","model":"sonnet","costUsd":0.38,
 "summary":"Replaces the day-count proration with a second-resolution calculation so a plan change at 23:59 no longer bills a full extra day. The new `prorate()` is covered by the existing fixtures and two new ones for the boundary.\n\nThe arithmetic is right, but rounding is done per line item rather than per invoice, which can leave the total a cent off.",
 "suggestedVerdict":"comment","files":6,"additions":142,"deletions":38,
 "intent":{"issue":"BILL-418","verdict":"partial","body":"The issue asks for correct proration on **upgrades and downgrades**. This handles upgrades; the downgrade path still uses the old day-count helper."},
 "findings":[
  {"id":"a1","severity":"blocker","path":"src/billing/prorate.ts","line":58,"title":"Rounds each line item, so the invoice total can drift by a cent","body":"`Math.round` runs inside the `map`, so three lines of 33.333… each round to 33.33 and the invoice totals 99.99 instead of 100.00. Round once, on the total, and distribute the remainder.","suggestion":"const total = round(sum(lines));","anchored":true},
  {"id":"b2","severity":"convention","path":"src/billing/prorate.ts","line":12,"title":"Money is a plain number here; the repo uses `Money`","body":"Everywhere else in `billing/` amounts are `Money` values (see `invoice.ts`). Mixing in raw numbers is how the double-charge in #847 slipped through.","anchored":true},
  {"id":"c3","severity":"nit","path":"test/prorate.test.ts","line":31,"title":"Test name says \"half\" but asserts a third","body":"The case title and the expected value disagree; one of them is stale.","anchored":false}]}
JSON
echo '{"slug":"acme/billing-api","pr":873,"head":"9f3c2a1d0e","base":"main","title":"x","url":"u","provider":"claude","model":"sonnet","costUsd":0.38}' > "$DIR/jobs/$READY/preview/meta.json"

mkjob "j$((NOW-7200))-33333" acme/widgets 2452 "Bump the image pipeline to Node 22" failed $((NOW-7200)) '{"pid":1,"error":"timeout","errorDetail":"timed out after 900s"}'
mkjob "j$((NOW-3500))-44444" acme/widgets 2455 "Cache the feature-flag lookup per request" done $((NOW-3500)) \
  '{"pid":1,"result":{"counts":"🟡 1 risk · ⚪ 1 nit","findings":2,"reviewUrl":"https://github.com/acme/widgets/pull/2455#pullrequestreview-1","costUsd":0.27}}'

# publish the state the app reads
GOBLIN_HOME="$DIR" GOBLIN_APP="$ROOT" "$ROOT/bin/goblin" status --json >/dev/null 2>&1 || true
echo "$READY"
