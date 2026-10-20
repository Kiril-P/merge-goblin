#!/usr/bin/env bash
# fleet.sh — what is each teammate's Goblin up to?
#
# There is no server, so "is alice's Goblin alive" can only be read off what it leaves
# on GitHub. Two traces, both cheap (one call each per watched repo, no per-PR loop):
#
#   claim meta refs   refs/goblin/meta/pr-<n>/<head>/<epoch>-<login>   (lib/claim.sh)
#                     written when a scheduled review starts, deleted when it ends, so
#                     one that exists means "reviewing right now" (or crashed, if old)
#   review markers    the hidden <!-- goblin:finding|intent --> markers on the inline
#                     and issue comments a review posts, newest first, repo-wide
#
# Your own Goblin is also read from this machine (when the scheduler last ran), which
# is the only one of these that sees an idle Goblin: a teammate with nothing to review
# leaves no trace at all, so the honest answers are "active", "last seen <when>" and
# "no sign yet" — never "offline".
#
# goblin fleet status [--json] [--refresh]   — reads only; the one file it writes is
# its own cache (fleet-status.json), so the Team pane can ask every time it opens.

FLEET_TTL_SECS=180        # a few minutes: claims come and go on the scan interval
FLEET_MAX_REPOS=10        # three calls per repo; a long watch list must not stall the pane
FLEET_CALL_TIMEOUT=12
FLEET_RECENT=5            # per member

fleet_cache_path() { printf '%s/fleet-status.json' "$GOBLIN_HOME"; }

# fleet_gh <path> — one read, bounded, never prompting. Fails on anything that is not
# a JSON array, so a rate-limit or 404 object can never be read as "no activity".
fleet_gh() {
  local out
  out="$(GH_PROMPT_DISABLED=1 run_with_timeout "$FLEET_CALL_TIMEOUT" gh api "$1" 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# fleet_traces <slug> -> JSON lines {login, at, repo, pr, kind} ; rc 1 if GitHub could
# not be read at all for this repo.
fleet_traces() {
  local slug="$1" ok=0 raw ns="$GOBLIN_MARKER_NS" legacy="$GOBLIN_MARKER_NS_LEGACY"
  if raw="$(fleet_gh "repos/$slug/git/matching-refs/$GOBLIN_SLUG/meta/")"; then
    ok=1
    # refs/goblin/meta/pr-12/<head>/1700000000-alice[.adopted] — a login may contain
    # "-", so split on the FIRST one only.
    printf '%s' "$raw" | jq -c --arg repo "$slug" '
      .[] | (.ref // "") | split("/") | select(length >= 6)
      | (.[3] | ltrimstr("pr-") | tonumber?) as $pr
      | (.[-1] | sub("\\.adopted$"; "")) as $tail
      | ($tail | index("-")) as $i
      | select($pr != null and $i != null)
      | { login: $tail[$i+1:], at: ($tail[0:$i] | tonumber?), repo: $repo, pr: $pr, kind: "claim" }
      | select(.at != null and .login != "")' 2>/dev/null
  fi
  local path
  for path in "pulls/comments" "issues/comments"; do
    if raw="$(fleet_gh "repos/$slug/$path?sort=created&direction=desc&per_page=100")"; then
      ok=1
      printf '%s' "$raw" | jq -c --arg repo "$slug" --arg ns "$ns" --arg legacy "$legacy" '
        .[] | select((.body // "") | test("<!-- (" + $ns + "|" + $legacy + "):(finding|intent|review) "))
        | { login: (.user.login // ""),
            at: ((.created_at // "") | fromdateiso8601? // null),
            repo: $repo,
            pr: (((.pull_request_url // .issue_url // "") | split("/") | last) | tonumber?),
            kind: "review" }
        | select(.login != "" and .at != null and .pr != null)' 2>/dev/null
    fi
  done
  [ "$ok" -eq 1 ]
}

# fleet_collect -> the report as JSON ; rc 1 when not one repo could be read.
fleet_collect() {
  local me fleet interval ttl now tmp slug read=0 failed=0 n=0 last_run
  me="$GOBLIN_LOGIN"
  fleet="$(cfg_get_json '.fleet // []' '[]')"
  interval="$(cfg_get '.intervalSeconds' 300)"; case "$interval" in ''|*[!0-9]*) interval=300 ;; esac
  ttl="$(cfg_get '.claimTtlSecs' 3600)"; case "$ttl" in ''|*[!0-9]*) ttl=3600 ;; esac
  now="$(now_epoch)"
  last_run="$(jq -r '[.lastRunFinished // 0, .lastRunStarted // 0] | max' "$STATUS" 2>/dev/null)"
  case "$last_run" in ''|*[!0-9]*) last_run=0 ;; esac
  tmp="$(mktemp -d)" || return 1
  : > "$tmp/traces"

  while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    n=$((n + 1)); [ "$n" -gt "$FLEET_MAX_REPOS" ] && break
    if fleet_traces "$slug" >> "$tmp/traces"; then read=$((read + 1)); else failed=$((failed + 1)); fi
  done <<EOF
$(cfg_repos_enabled)
EOF
  if [ "$read" -eq 0 ] && [ "$failed" -gt 0 ]; then rm -rf "$tmp"; return 1; fi

  jq -s --argjson fleet "$fleet" --arg me "$me" --argjson now "$now" --argjson interval "$interval" \
     --argjson ttl "$ttl" --argjson lastRun "$last_run" --argjson cap "$FLEET_RECENT" \
     --argjson read "$read" --argjson failed "$failed" '
    . as $all
    | ($interval * 2 + 60) as $window
    | ($fleet | map(select(type == "string" and . != "")) | unique) as $logins
    | { ok: true, at: $now, me: $me, intervalSeconds: $interval, activeWindowSecs: $window,
        reposRead: $read, reposFailed: $failed,
        members: [ $logins[] as $l
          | ([ $all[] | select((.login | ascii_downcase) == ($l | ascii_downcase)) ]) as $mine
          | ([ $mine[] | select(.kind == "claim" and ($now - .at) < $ttl) ]
             | sort_by(-.at) | unique_by(.repo + "#" + (.pr | tostring)) | sort_by(-.at)) as $reviewing
          | ([ $mine[] | select(.kind == "review") ]
             | sort_by(-.at) | unique_by(.repo + "#" + (.pr | tostring)) | sort_by(-.at) | .[0:$cap]) as $recent
          | ($l == $me) as $isMe
          | ([ $mine[].at ] + (if $isMe and $lastRun > 0 then [$lastRun] else [] end) | max) as $seen
          | { login: $l, me: $isMe, lastSeen: $seen,
              status: ( if $seen == null then "unknown"
                        elif ($now - $seen) <= $window then "active"
                        else "seen" end ),
              reviewing: [ $reviewing[] | {repo, pr, at} ],
              recent: [ $recent[] | {repo, pr, at} ] } ] }' "$tmp/traces"
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

cmd_fleet_status() {
  local as_json=false refresh=false cache report age
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) as_json=true; shift ;;
      --refresh) refresh=true; shift ;;
      *) shift ;;
    esac
  done

  fleet_say() { # <json> — print it as JSON or as a few lines of text
    if [ "$as_json" = true ]; then printf '%s\n' "$1"; return 0; fi
    printf '%s' "$1" | jq -r '
      if .ok != true then "fleet status unavailable: \(.message // .error)"
      elif (.members | length) == 0 then "no fleet: add teammates with  goblin fleet add <login>"
      else .members[] | "\(.login)\(if .me then " (you)" else "" end)  \(.status)"
        + (if .lastSeen then "  last seen \(((now - .lastSeen) / 60 | floor))m ago" else "" end)
        + (if (.reviewing | length) > 0 then "  reviewing " + ([.reviewing[] | "\(.repo)#\(.pr)"] | join(", ")) else "" end)
      end'
  }

  local fleet_n; fleet_n="$(cfg_get_json '.fleet // [] | length' 0)"
  if [ "${fleet_n:-0}" = "0" ]; then
    fleet_say "$(jq -nc --argjson at "$(now_epoch)" '{ok:true, at:$at, members:[], reposRead:0, reposFailed:0}')"
    return 0
  fi

  cache="$(fleet_cache_path)"
  if [ "$refresh" != true ] && [ -f "$cache" ]; then
    age=$(( $(now_epoch) - $(jq -r '.at // 0' "$cache" 2>/dev/null || echo 0) ))
    # A cache made for a different team is no answer for this one.
    if [ "$age" -lt "$FLEET_TTL_SECS" ] && [ "$age" -ge 0 ] \
       && jq -e --argjson f "$(cfg_get_json '.fleet // []' '[]')" '([.members[].login] | sort) == ($f | unique)' "$cache" >/dev/null 2>&1; then
      fleet_say "$(cat "$cache")"
      return 0
    fi
  fi

  if ! engine_auth_lite >/dev/null 2>&1; then
    fleet_say '{"ok":false,"error":"not_authenticated","message":"GitHub is not signed in as the configured account."}'
    return 0
  fi
  if ! report="$(fleet_collect)" || [ -z "$report" ]; then
    # Offline, or every repo refused. An older answer, marked stale, beats a blank pane.
    if [ -f "$cache" ] && jq -e '.ok == true' "$cache" >/dev/null 2>&1; then
      fleet_say "$(jq -c '. + {stale:true}' "$cache")"
    else
      fleet_say '{"ok":false,"error":"unreachable","message":"Could not reach GitHub to see what the team is doing."}'
    fi
    return 0
  fi
  goblin_ensure_dirs
  printf '%s' "$report" | jq -c . | atomic_write "$cache"
  fleet_say "$(printf '%s' "$report" | jq -c .)"
}
