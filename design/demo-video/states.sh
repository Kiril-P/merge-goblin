#!/usr/bin/env bash
# Render the real popover in each state the video needs, from the demo sandbox.
set -u
cd "$(dirname "$0")/../.."   # the repo root; build the app first with ./build.sh --dev
APP="build/Merge Goblin Dev.app/Contents/MacOS/GoblinBar"; OUT="${1:-design/demo-video/ui}"; mkdir -p "$OUT"
state() { # name phase|none|ready  seconds-ago
  local name=$1 phase=$2 D=/tmp/mgv-$1
  scripts/demo-home.sh $D > /tmp/mgv-ready.txt
  local READY; READY=$(tail -1 /tmp/mgv-ready.txt)
  for j in $D/jobs/*; do [ "$(basename "$j")" = "$READY" ] || rm -rf "$j"; done
  if [ "$phase" = none ]; then rm -rf "$D/jobs/$READY"
  elif [ "$phase" != ready ]; then
    jq --arg ph "$phase" --argjson pid "$(cat $D/demo-sleeper.pid)" --argjson at "$(($(date +%s)-${3:-20}))" \
      '.phase=$ph | .pid=$pid | .createdAt=$at | .updatedAt=$at | del(.result)' "$D/jobs/$READY/job.json" > /tmp/mgv-j && mv /tmp/mgv-j "$D/jobs/$READY/job.json"
  fi
  GOBLIN_HOME=$D GOBLIN_APP=$PWD bin/goblin status --json >/dev/null 2>&1 < /dev/null || true
  rm -rf /tmp/mgv-shots; GOBLIN_HOME=$D "$APP" --snapshot /tmp/mgv-shots >/dev/null 2>&1 < /dev/null
  for f in popover-light popover-dark review-ready-light field-typed-light review-running-light; do
    [ -f /tmp/mgv-shots/$f.png ] && cp /tmp/mgv-shots/$f.png "$OUT/$name-$f.png"; done
  kill "$(cat $D/demo-sleeper.pid)" 2>/dev/null; echo "$name done"
}
state idle none; state fetching fetching 3; state reading reading 9; state reviewing reviewing 41; state ready ready
