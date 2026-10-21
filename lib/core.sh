#!/usr/bin/env bash
# core.sh — logging, time, notifications, and the timeout watchdog.
# Written for bash 3.2 (what /bin/bash on macOS actually is): no associative
# arrays, no mapfile, no ${var,,}.

# launchd hands us a minimal PATH. Include the usual homes for user-installed
# CLIs (claude lives in ~/.local/bin, codex in /opt/homebrew/bin).
#
# GOBLIN_PATH_FIRST goes in front of all of it. It exists for the test suite: the
# fixtures (fake gh, fake model CLI) must beat the real binaries in /opt/homebrew/bin
# even in a child process that re-sources this file.
export PATH="${GOBLIN_PATH_FIRST:+$GOBLIN_PATH_FIRST:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:$HOME/bin:$PATH"

now_epoch()      { date +%s; }
midnight_epoch() { date -v0H -v0M -v0S +%s; }
tomorrow_epoch() { date -v+1d -v0H -v0M -v0S +%s; }
week_ago_epoch() { echo $(( $(date +%s) - 604800 )); }

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Send all further output to the log file, rotating first.
log_open() {
  if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 4000 ]; then
    tail -n 1500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
  exec >> "$LOG" 2>&1
}

die() { log "FATAL: $*"; exit 1; }

# notify_payload <title> <message> <sound> <kind> — one line of notify.jsonl.
#
# `kind` is what happened (ready, posted, failed, started, budget) and `job` is the
# manual review it is about, when there is one. The app needs both to offer "Post"
# on a ready banner and to open THAT review on a click, rather than whichever review
# happens to be waiting. A job id that is not the engine's own shape is left out.
notify_payload() {
  local job="${GOBLIN_JOB_ID:-}"
  printf '%s' "$job" | grep -qE '^j[0-9]{10}-[0-9]{1,6}$' || job=""
  jq -nc --arg t "$1" --arg m "$2" --arg s "$3" --arg k "$4" --arg j "$job" \
     --argjson at "$(now_epoch)" \
     '{at:$at, title:$t, message:$m, sound:$s, kind:$k} + (if $j != "" then {job:$j} else {} end)'
}

# notify <type> <title> <message> [kind] — gated on config notify.<type>. `kind`
# defaults to the type; a finished preview is type "posted" (same switch) but kind "ready".
notify() {
  local type="$1" title="$2" message="$3" kind="${4:-$1}" sound="true"
  if command -v cfg_get >/dev/null 2>&1; then
    [ "$(cfg_get ".notify.${type}" true)" = "true" ] || return 0
    sound="$(cfg_get '.notify.sound' true)"
  fi
  # The message carries attacker-controlled text — a PR title, from anyone who can
  # open a PR on a watched repo. It is passed as argv and read with `item of argv`,
  # never interpolated into the script source. Escaping only `"` (as this used to)
  # leaves a backslash free to close the string literal, so a title ending in `\`
  # turned the whole thing into an AppleScript syntax error and silently dropped
  # the notification — `|| true` meant nobody ever found out.
  # With the menu bar app running, queue the request for it: a banner posted by the
  # app wears the Goblin's icon, where osascript's wears Script Editor's. Without the
  # app, osascript is a wrong icon rather than a missing notification.
  if pgrep -x GoblinBar >/dev/null 2>&1; then
    goblin_ensure_dirs 2>/dev/null || true
    local q="$GOBLIN_HOME/notify.jsonl"
    notify_payload "$title" "$message" "$([ "$sound" = "true" ] && echo Glass || echo '')" "$kind" >> "$q" 2>/dev/null
    if [ "$(wc -l < "$q" 2>/dev/null || echo 0)" -gt 200 ]; then
      tail -n 50 "$q" > "$q.tmp" 2>/dev/null && mv "$q.tmp" "$q"
    fi
    return 0
  fi
  local script='on run argv
  display notification (item 2 of argv) with title (item 1 of argv)'
  [ "$sound" = "true" ] && script="$script sound name \"Glass\""
  script="$script
end run"
  printf '%s' "$script" | osascript - "$title" "$message" >/dev/null 2>&1 || true
}

# run_with_timeout <secs> <cmd...>
# macOS ships no timeout(1)/gtimeout, and a hung model call would otherwise wedge
# the whole run until the 3h stale-lock sweep. Returns 124 on timeout, else the
# child's exit code.
run_with_timeout() {
  local secs="$1"; shift
  # `<&0` is load-bearing: POSIX says an asynchronous command's stdin is assigned
  # to /dev/null unless explicitly redirected, which would silently swallow a
  # prompt the caller piped in. This passes the caller's stdin through.
  "$@" <&0 &
  local child=$!
  (
    local waited=0
    while [ "$waited" -lt "$secs" ]; do
      kill -0 "$child" 2>/dev/null || exit 0
      sleep 1
      waited=$((waited + 1))
    done
    # grace, then force
    kill -TERM "$child" 2>/dev/null
    sleep 5
    kill -KILL "$child" 2>/dev/null
  ) &
  local watcher=$!
  local rc=0
  wait "$child" 2>/dev/null || rc=$?
  # If the watcher already exited, the child finished on its own.
  if kill -0 "$watcher" 2>/dev/null; then
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null || true
  else
    [ "$rc" -ne 0 ] && rc=124
  fi
  return "$rc"
}

# Single-instance lock. Stale after 3h (a review can legitimately take minutes).
lock_acquire() {
  if [ -d "$LOCKDIR" ]; then
    # A run killed outright (launchctl bootout on reinstall, a crash, SIGKILL) never
    # releases its lock, and going by age alone that silenced the scheduler for three
    # hours. The owner's pid says at once whether anyone still holds it.
    local owner; owner="$(cat "$LOCKDIR/pid" 2>/dev/null)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      log "removing the lock of a run that died (pid $owner)"
      rm -rf "$LOCKDIR"
    elif [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +180 2>/dev/null)" ]; then
      log "removing stale lock"
      rm -rf "$LOCKDIR"
    else
      return 1
    fi
  fi
  mkdir "$LOCKDIR" 2>/dev/null || return 1
  echo "$$" > "$LOCKDIR/pid" 2>/dev/null || true
  return 0
}
lock_release() { rm -rf "$LOCKDIR" 2>/dev/null || true; }

# Stable short hash of a string (used for finding ids and fleet assignment).
goblin_hash() { printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-12; }

# atomic_write <dest> — write stdin to dest via a temp file in the same directory.
#
# The menu bar app watches these files and re-reads on every change, so a reader
# can arrive mid-write. A plain redirect truncates first, which means the app
# reliably sees a zero-byte or half-written JSON file and renders an empty panel.
# The empty check matters as much as the rename: a jq program that failed leaves
# nothing on stdout, and replacing good state with an empty file is worse than
# keeping the stale copy.
atomic_write() {
  local dest="$1" tmp rc
  tmp="$(mktemp "${dest}.XXXXXX")" || return 1
  cat > "$tmp"; rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
    mv -f "$tmp" "$dest" && return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# Portable lowercase (bash 3.2 has no ${x,,}).
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Truncate a string to N chars.
trunc() { printf '%s' "$1" | cut -c "1-$2"; }

# gh_api_all <path> — every page of a GitHub list endpoint, as ONE JSON array.
#
# `gh api --paginate ... --jq EXPR` runs EXPR once PER PAGE. Any filter that reduces the
# list (`[...] | first`, `| min`, `| last`, `[...]`) therefore printed one answer per page
# on a PR with more than 100 comments: two arrays where one was expected, or a `null`
# from page one followed by the real id from page two. Nothing failed loudly; the
# answers were just wrong. So pages are fetched raw, merged here, and every reducing
# filter runs once over the whole list. `jq -s` accepts both the back-to-back pages gh
# prints and a single array.
#
# Fails (non-zero, nothing on stdout) when gh fails or any page is not an array — a
# rate-limit error object must never be read as "an empty list".
gh_api_all() {
  local raw
  raw="$(gh api --paginate "$1" 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | jq -cs 'if length > 0 and all(.[]; type == "array") then add else error("not a list") end' 2>/dev/null
}
