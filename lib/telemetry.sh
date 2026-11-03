#!/usr/bin/env bash
# telemetry.sh — optional, anonymous usage counts. OFF unless a person turns it on.
#
# This tool reads private pull requests, so the rule is: nothing leaves the machine
# that could identify a repo, a PR, a person or a line of code. What is sent, in full:
#
#   id          a random install id, made when telemetry is switched on (not derived from
#               the GitHub login, the machine or anything else)
#   version     the Goblin's version
#   os, arch    macOS major version and CPU architecture
#   event       "review"
#   status      posted | previewed | failed
#   provider    claude | codex | cursor
#   model       the model name the review ran on
#   effort      the reasoning effort, or empty
#   error       for a failure only, its kind (quota, timeout, auth, network, …)
#   seconds     how long the AI run took
#
# `goblin telemetry show` prints the last thing sent, byte for byte. With no collector
# configured (GOBLIN_TELEMETRY_URL in brand.sh, empty here) turning it on sends nothing:
# the payload is only written to telemetry-last.json so you can see it.

TELEMETRY_LAST="$GOBLIN_HOME/telemetry-last.json"

telemetry_on() { [ "$(cfg_get '.telemetry.enabled' false)" = true ]; }

telemetry_url() {
  local u="${GOBLIN_TELEMETRY_URL_OVERRIDE:-$GOBLIN_TELEMETRY_URL}"
  case "$u" in https://*) printf '%s' "$u" ;; esac
}

telemetry_enable() {
  local id; id="$(cfg_get '.telemetry.id' '')"
  [ -n "$id" ] || id="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')"
  [ -n "$id" ] || id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  cfg_set --arg id "$id" '.telemetry.enabled = true | .telemetry.id = $id'
}

telemetry_disable() { cfg_set '.telemetry.enabled = false | .telemetry.id = ""'; rm -f "$TELEMETRY_LAST" 2>/dev/null; }

# telemetry_review <status> <provider> <model> <effort> <reason> <duration-ms>
# Called by events_append. Never fails, never waits for the network.
telemetry_review() {
  telemetry_on || return 0
  local st="$1" provider="$2" model="$3" effort="$4" reason="$5" ms="${6:-0}"
  case "$st" in posted|previewed|failed) ;; *) return 0 ;; esac
  case "$provider" in claude|codex|cursor) ;; *) return 0 ;; esac
  # Only an error KIND may leave: a lowercase word, never free text.
  printf '%s' "$reason" | grep -qE '^[a-z_]{1,24}$' || reason=""
  [ "$st" = failed ] || reason=""
  printf '%s' "$model" | grep -qE '^[A-Za-z0-9._:-]{1,64}$' || model=""
  local body os
  os="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
  body="$(jq -nc --arg id "$(cfg_get '.telemetry.id' '')" --arg v "$GOBLIN_VERSION" \
    --arg os "${os:-}" --arg arch "$(uname -m)" --arg st "$st" --arg p "$provider" \
    --arg m "$model" --arg e "$effort" --arg err "$reason" --argjson ms "${ms:-0}" \
    '{schema:1, event:"review", id:$id, version:$v, os:$os, arch:$arch, status:$st,
      provider:$p, model:$m, effort:$e, error:$err, seconds:(($ms/1000)|floor)}' 2>/dev/null)" || return 0
  [ -n "$body" ] || return 0
  printf '%s\n' "$body" > "$TELEMETRY_LAST" 2>/dev/null
  local url; url="$(telemetry_url)"
  [ -n "$url" ] || return 0
  ( curl -fsS --max-time 5 -X POST -H 'Content-Type: application/json' -d "$body" "$url" \
      >/dev/null 2>&1 & ) 2>/dev/null
  return 0
}

cmd_telemetry() {
  case "${1:-status}" in
    on)  cfg_ensure; telemetry_enable
         echo "telemetry on — anonymous review counts; run '$GOBLIN_SLUG telemetry show' to see exactly what is sent"
         [ -n "$(telemetry_url)" ] || echo "(no collector is configured in this build, so nothing is actually sent)" ;;
    off) cfg_ensure; telemetry_disable; echo "telemetry off" ;;
    show) if [ -f "$TELEMETRY_LAST" ]; then cat "$TELEMETRY_LAST"; else echo "nothing sent yet"; fi ;;
    status|"") if telemetry_on; then echo "on${GOBLIN_TELEMETRY_URL:+ → collector configured}"; else echo "off"; fi ;;
    *) echo "usage: $GOBLIN_SLUG telemetry [on|off|show|status]" >&2; return 2 ;;
  esac
}
