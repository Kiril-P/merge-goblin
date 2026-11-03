#!/usr/bin/env bash
# scripts/fleet-stats.sh [days] [--raw [since-epoch]] — the anonymous counts from every
# install that shares them (lib/telemetry.sh), read from the collector (collector/).
#
#   scripts/fleet-stats.sh 30          aggregates as JSON: installs per day, versions,
#                                      reviews by provider/model/effort with failure rates
#                                      and durations, failure kinds, which settings are on
#                                      across installs, which commands and screens get used
#   scripts/fleet-stats.sh --raw 0     raw event rows
#
# The read token lives in the login keychain (service merge-goblin-telemetry, account
# read), or in GOBLIN_TELEMETRY_READ_TOKEN. The collector refuses reads without it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/lib/brand.sh"
BASE="${GOBLIN_TELEMETRY_URL%/v1/events}"
TOKEN="${GOBLIN_TELEMETRY_READ_TOKEN:-$(security find-generic-password -s merge-goblin-telemetry -a read -w 2>/dev/null || true)}"
[ -n "$TOKEN" ] || { echo "no read token: set GOBLIN_TELEMETRY_READ_TOKEN or add it to the keychain" >&2; exit 1; }

if [ "${1:-}" = --raw ]; then
  curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/v1/events?since=${2:-0}&limit=5000"
else
  curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/v1/stats?days=${1:-30}"
fi
