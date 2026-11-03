#!/usr/bin/env bash
# telemetry.sh — anonymous usage counts, and the local usage log they are built from.
#
# ON by default, with an off switch in Settings › General › Privacy, at the end of setup,
# and `goblin telemetry off`. DO_NOT_TRACK=1 or GOBLIN_TELEMETRY=off in the environment
# also turns it off. The point is to learn which models, efforts, settings and screens
# people actually use, so the app can be improved and pruned.
#
# This tool reads private pull requests, so the rule is: nothing leaves the machine that
# could identify a repo, a PR, a person or a line of code. Every event carries:
#
#   id          a random install id (telemetry-id), made the first time anything is sent
#               and deleted when telemetry is turned off. Not derived from anything.
#   version     the Goblin's version;  os, arch: macOS major version, CPU architecture
#
# and then one of:
#
#   review      status (posted|previewed|failed), provider, model, effort, error KIND for
#               a failure, seconds, number of findings, manual (asked for by number) or
#               scheduled, focus, mode
#   daily       once a day: the provider/model/effort in use, which settings are on (only
#               booleans and fixed enum values), how many repos / teammates (numbers), and
#               how often each command and screen was used since the last one (`usage`,
#               counted from the local usage log below), and how this install's posted
#               findings fared (numbers from the `goblin stats` cache: found, addressed,
#               discussed, silent)
#
# The collector (collector/ in this repo) re-validates every field and drops anything
# else. `goblin telemetry show` prints the last payload, byte for byte.
#
# THE LOCAL USAGE LOG (usage.log) is a line per command or screen, "epoch name". It never
# leaves the Mac by itself: it feeds `goblin insights` and the daily counts.

TELEMETRY_LAST="$GOBLIN_HOME/telemetry-last.json"
TELEMETRY_ID_FILE="$GOBLIN_HOME/telemetry-id"
TELEMETRY_DAILY_STAMP="$GOBLIN_HOME/telemetry-daily.stamp"
USAGE_LOG="$GOBLIN_HOME/usage.log"
USAGE_LOG_MAX=400000      # bytes; past this the older half is dropped

telemetry_on() {
  [ "${DO_NOT_TRACK:-}" = 1 ] && return 1
  case "${GOBLIN_TELEMETRY:-}" in off|0|false) return 1 ;; esac
  [ "$(cfg_get '.telemetry.choice' '')" != off ]
}

telemetry_url() {
  local u="${GOBLIN_TELEMETRY_URL_OVERRIDE:-$GOBLIN_TELEMETRY_URL}"
  case "$u" in https://*) printf '%s' "$u" ;; esac
}

telemetry_id() {
  local id; id="$(cat "$TELEMETRY_ID_FILE" 2>/dev/null)"
  if ! printf '%s' "$id" | grep -qE '^[a-f0-9-]{16,40}$'; then
    id="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')"
    [ -n "$id" ] || id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    mkdir -p "$GOBLIN_HOME" 2>/dev/null; printf '%s\n' "$id" > "$TELEMETRY_ID_FILE" 2>/dev/null
  fi
  printf '%s' "$id"
}

telemetry_enable()  { cfg_set '.telemetry.choice = "on"'; }
telemetry_disable() {
  cfg_set '.telemetry.choice = "off"'
  rm -f "$TELEMETRY_ID_FILE" "$TELEMETRY_LAST" "$TELEMETRY_DAILY_STAMP" 2>/dev/null
}

# telemetry_send <json-without-envelope> — adds the envelope, records it, posts it in the
# background. Never fails, never waits for the network.
telemetry_send() {
  telemetry_on || return 0
  local body os
  os="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
  body="$(printf '%s' "$1" | jq -c --arg id "$(telemetry_id)" --arg v "$GOBLIN_VERSION" \
    --arg os "${os:-}" --arg arch "$(uname -m)" \
    '{schema:1, id:$id, version:$v, os:$os, arch:$arch} + .' 2>/dev/null)" || return 0
  [ -n "$body" ] || return 0
  printf '%s\n' "$body" > "$TELEMETRY_LAST" 2>/dev/null
  local url; url="$(telemetry_url)"
  [ -n "$url" ] || return 0
  ( curl -fsS --max-time 5 -X POST -H 'Content-Type: application/json' -d "$body" "$url" \
      >/dev/null 2>&1 & ) 2>/dev/null
  return 0
}

# telemetry_review <status> <provider> <model> <effort> <reason> <duration-ms>
# Called by events_append. The extra facts come from the environment the engine sets.
telemetry_review() {
  telemetry_on || return 0
  local st="$1" provider="$2" model="$3" effort="$4" reason="$5" ms="${6:-0}"
  case "$st" in posted|previewed|failed) ;; *) return 0 ;; esac
  case "$provider" in claude|codex|cursor) ;; *) return 0 ;; esac
  # Only an error KIND may leave: a lowercase word, never free text.
  printf '%s' "$reason" | grep -qE '^[a-z_]{1,24}$' || reason=""
  [ "$st" = failed ] || reason=""
  printf '%s' "$effort" | grep -qE '^[a-z]{3,8}$' || effort=""
  printf '%s' "$ms" | grep -qE '^[0-9]{1,9}$' || ms=0
  printf '%s' "$model" | grep -qE '^[A-Za-z0-9._:-]{1,64}$' || model=""
  local findings="${GOBLIN_T_FINDINGS:-}" focus="${GOBLIN_FOCUS:-full}" mode=post manual=false
  printf '%s' "$findings" | grep -qE '^[0-9]{1,4}$' || findings=-1
  case "$focus" in full|security|summary) ;; *) focus=full ;; esac
  [ "${PREVIEW:-false}" = true ] && mode=preview
  [ -n "${GOBLIN_JOB_ID:-}" ] && manual=true
  telemetry_send "$(jq -nc --arg st "$st" --arg p "$provider" --arg m "$model" --arg e "$effort" \
    --arg err "$reason" --argjson ms "$ms" --argjson f "$findings" --arg focus "$focus" \
    --arg mode "$mode" --argjson manual "$manual" \
    '{event:"review", status:$st, provider:$p, model:$m, effort:$e, error:$err,
      seconds:(($ms/1000)|floor), findings:$f, manual:$manual, focus:$focus, mode:$mode}')"
}

# --- the local usage log -------------------------------------------------------

# usage_note <name> — one line, "epoch name". Names are fixed words from the code (a verb,
# "panel.<key>", "ui.<screen>"), checked here so nothing else can land in the file.
usage_note() {
  local name="$1"
  printf '%s' "$name" | grep -qE '^[a-z][a-z0-9._-]{0,47}$' || return 0
  [ -d "$GOBLIN_HOME" ] || return 0
  printf '%s %s\n' "$(date +%s)" "$name" >> "$USAGE_LOG" 2>/dev/null || return 0
  local size; size="$(wc -c < "$USAGE_LOG" 2>/dev/null | tr -d ' ')"
  if [ "${size:-0}" -gt "$USAGE_LOG_MAX" ]; then
    local n; n="$(wc -l < "$USAGE_LOG" | tr -d ' ')"
    tail -n "$((n / 2))" "$USAGE_LOG" > "$USAGE_LOG.tmp" 2>/dev/null && mv "$USAGE_LOG.tmp" "$USAGE_LOG"
  fi
  return 0
}

# usage_counts <since-epoch> -> {"name": n, ...}
usage_counts() {
  local since="${1:-0}"
  [ -f "$USAGE_LOG" ] || { echo '{}'; return 0; }
  awk -v s="$since" '$1 >= s && NF == 2 { c[$2]++ } END { for (k in c) printf "%s %d\n", k, c[k] }' "$USAGE_LOG" \
    | jq -Rn '[inputs | split(" ") | {key: .[0], value: (.[1] | tonumber)}] | from_entries'
}

# The settings worth knowing about across installs: booleans and fixed enums only.
telemetry_settings_json() {
  cfg_get_json '{
    enabled, verdictMode, allowApprove, autoPost, reviewMine, reviewMineDrafts,
    manualReviewMode, incrementalReview, postCommitStatus, postIntentComment,
    fleetAssignment, skipIfHumanReviewed, refutePass,
    skipBots: (.skip.bots != false), skipDocsOnly: (.skip.docsOnly == true),
    notifyStarted: .notify.started, notifyPosted: .notify.posted, notifyFailed: .notify.failed,
    notifySound: .notify.sound, updateNotify: .update.notify,
    hasFallback: ((.providerFallback // []) | length > 0),
    budgetCapUsd, maxReviewsPerDay, maxReviewsPerRun, maxFindings, intervalSeconds, timeoutSecs,
    reposWithOwnProvider: ([.repos[]? | select((.provider // "") != "")] | length),
    reposWithOwnSkip: ([.repos[]? | select(.skip != null)] | length)
  } | with_entries(select(.value | type == "boolean" or type == "number"
                        or (type == "string" and test("^[a-z]{1,16}$"))))' '{}'
}

# telemetry_daily — at most once every 20 hours, from the scheduled run.
telemetry_daily() {
  telemetry_on || return 0
  local now last; now="$(now_epoch)"
  last="$(stat -f %m "$TELEMETRY_DAILY_STAMP" 2>/dev/null || echo 0)"
  [ $((now - last)) -ge 72000 ] || return 0
  mkdir -p "$GOBLIN_HOME" 2>/dev/null; : > "$TELEMETRY_DAILY_STAMP"
  local since=$(( last > 0 ? last : now - 86400 )) p
  p="$(cfg_get '.provider' claude)"
  telemetry_send "$(jq -nc --argjson s "$(telemetry_settings_json)" --argjson u "$(usage_counts "$since")" \
    --argjson repos "$(cfg_get_json '[.repos[]? | select(.enabled != false)] | length' 0)" \
    --argjson fleet "$(cfg_get_json '(.fleet // []) | length' 0)" \
    --arg p "$p" --arg m "$(cfg_get ".providers.$p.model" '')" --arg e "$(provider_effort "$p")" \
    --argjson q "$(jq -c '.' "$GOBLIN_HOME/stats.json" 2>/dev/null || echo '{}')" \
    '{event:"daily", provider:$p, model:(if ($m|test("^[A-Za-z0-9._:-]{1,64}$")) then $m else "" end),
      effort:$e, settings:$s, usage:$u, counts:{repos:$repos, fleet:$fleet},
      quality:($q | {findings, addressed, discussed, silent} | with_entries(select(.value | type == "number")))}')"
}

cmd_telemetry() {
  case "${1:-status}" in
    on)  cfg_ensure; telemetry_enable
         echo "telemetry on: anonymous counts; '$GOBLIN_SLUG telemetry show' prints exactly what is sent" ;;
    off) cfg_ensure; telemetry_disable; echo "telemetry off: nothing is sent, and the install id is deleted" ;;
    show) if [ -f "$TELEMETRY_LAST" ]; then cat "$TELEMETRY_LAST"; else echo "nothing sent yet"; fi ;;
    ui)  usage_note "ui.${2:-}" ;;
    status|"") if telemetry_on; then echo on; else echo off; fi ;;
    *) echo "usage: $GOBLIN_SLUG telemetry [on|off|show|status]" >&2; return 2 ;;
  esac
}
