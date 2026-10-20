#!/usr/bin/env bash
# stats.sh — how did the findings we posted actually fare?
#
# Every inline comment the Goblin posts carries a `finding` marker (render_inline_body).
# This reads those threads back from GitHub and sorts each into one of three piles:
#
#   addressed   the thread is resolved, or GitHub marked it outdated (the code under
#               it changed). Outdated is only a PROXY: an unrelated edit to those
#               lines also outdates a thread, so read this as "likely addressed",
#               never as "was right".
#   discussed   still open, but somebody other than us replied.
#   silent      still open, nobody said anything.
#
# Silent is not "wrong" either — plenty of good findings are read and ignored — but a
# rate that falls after a prompt change is the only signal there is that the change hurt,
# which is why this exists. Findings that could not be pinned to a diff line ride in the
# review body, not a thread, and are not counted here.
#
# goblin stats [--json] [--days N] [--refresh]

STATS_TTL_SECS=21600          # 6h: the numbers move on the scale of days
STATS_MAX_PRS=60              # most recent first; a sweep is one API call per PR
STATS_CALL_TIMEOUT=30

STATS_THREADS_QUERY='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){nodes{isResolved isOutdated comments(first:20){nodes{author{login} body createdAt}}}}}}}'

stats_cache_path() { printf '%s/stats.json' "$GOBLIN_HOME"; }

# stats_prs <days> -> JSON lines {slug,pr,at}: PRs we posted on in the window, newest
# first, one per PR. The repo comes from the event, or from its url for events written
# before the field existed.
stats_prs() {
  local days="$1" since
  since=$(( $(now_epoch) - days * 86400 ))
  [ -f "$EVENTS" ] || return 0
  jq -c --argjson since "$since" --argjson cap "$STATS_MAX_PRS" -s '
    [ .[] | select(.status == "posted" and (.at // 0) >= $since and (.number // 0) > 0)
      | { at, pr: .number,
          slug: ( if (.repo // "") != "" then .repo
                  else ((.url // "") | capture("github\\.com/(?<s>[^/]+/[^/]+)/pull/").s // "") end ) }
      | select(.slug != "") ]
    | sort_by(-.at) | unique_by(.slug + "#" + (.pr | tostring)) | sort_by(-.at) | .[0:$cap] | .[]' "$EVENTS" 2>/dev/null
}

# stats_threads <slug> <pr> <login> -> JSON [{severity,class}] for OUR threads, or
# non-zero when GitHub could not be asked.
stats_threads() {
  local slug="$1" pr="$2" login="$3" owner name raw
  owner="${slug%%/*}"; name="${slug#*/}"
  raw="$(GH_PROMPT_DISABLED=1 run_with_timeout "$STATS_CALL_TIMEOUT" gh api graphql \
          -f query="$STATS_THREADS_QUERY" -F owner="$owner" -F name="$name" -F number="$pr" 2>/dev/null)" || return 1
  printf '%s' "$raw" | jq -e '.data.repository.pullRequest.reviewThreads.nodes | type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$raw" | jq -c --arg me "$(lc "$login")" --arg ns "$GOBLIN_MARKER_NS" --arg legacy "$GOBLIN_MARKER_NS_LEGACY" '
    [ .data.repository.pullRequest.reviewThreads.nodes[]
      | (.comments.nodes // []) as $c
      | select(($c | length) > 0)
      | select((($c[0].author.login // "") | ascii_downcase) == $me)
      | ($c[0].body // "" | capture("<!-- (?:" + $ns + "|" + $legacy + "):finding (?<j>\\{.*?\\}) -->") // null) as $mk
      | select($mk != null)
      | ((try ($mk.j | fromjson | .severity) catch null) // "unknown") as $sev
      # The Goblin posts AS the user, so a reply from the same login is a person unless it
      # carries one of our markers.
      | ([ $c[1:][] | select(((((.author.login // "") | ascii_downcase) == $me)
                              and ((.body // "") | (contains("<!-- " + $ns + ":") or contains("<!-- " + $legacy + ":")))) | not) ] | length) as $replies
      | { severity: $sev,
          class: ( if (.isResolved or .isOutdated) then "addressed"
                   elif $replies > 0 then "discussed" else "silent" end ) } ]' 2>/dev/null
}

# stats_collect <days> -> the full report as JSON; rc 1 if nothing could be read at all.
stats_collect() {
  local days="$1" tmp prs_n=0 skipped=0 line slug pr threads
  tmp="$(mktemp -d)" || return 1
  : > "$tmp/rows"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    prs_n=$((prs_n + 1))
    slug="$(printf '%s' "$line" | jq -r .slug)"; pr="$(printf '%s' "$line" | jq -r .pr)"
    if threads="$(stats_threads "$slug" "$pr" "$GOBLIN_LOGIN")" && [ -n "$threads" ]; then
      jq -nc --arg s "$slug" --argjson p "$pr" --argjson t "$threads" '{slug:$s, pr:$p, threads:$t}' >> "$tmp/rows"
    else
      skipped=$((skipped + 1))
    fi
  done <<EOF
$(stats_prs "$days")
EOF
  if [ "$prs_n" -gt 0 ] && [ "$skipped" -eq "$prs_n" ]; then rm -rf "$tmp"; return 1; fi

  jq -s --argjson days "$days" --argjson at "$(now_epoch)" --argjson skipped "$skipped" \
    --argjson looked "$prs_n" '
    def count(c): [.[] | select(.class == c)] | length;
    def tally: { n: length, addressed: count("addressed"), discussed: count("discussed"), silent: count("silent") };
    ( [ .[] | .threads[] ] ) as $all
    | ($all | tally) as $t
    | { days: $days, at: $at, prs: ([.[] | select(.threads | length > 0)] | length),
        looked: $looked, skipped: $skipped,
        findings: $t.n, addressed: $t.addressed, discussed: $t.discussed, silent: $t.silent,
        addressedRate: (if $t.n == 0 then null else ($t.addressed / $t.n) end),
        bySeverity: ( $all | group_by(.severity) | map({ key: .[0].severity, value: tally }) | from_entries ),
        perPr: [ .[] | select(.threads | length > 0)
                 | { slug, pr, findings: (.threads | length),
                     addressed: (.threads | count("addressed")),
                     discussed: (.threads | count("discussed")),
                     silent:    (.threads | count("silent")) } ] }' "$tmp/rows"
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

stats_print() {
  printf '%s' "$1" | jq -r '
    def pct: if . == null then "—" else ((. * 100 | round | tostring) + "%") end;
    "last \(.days) days: \(.findings) finding(s) on \(.prs) PR(s)",
    "  likely addressed  \(.addressed)  (\(.addressedRate | pct))",
    "  discussed         \(.discussed)",
    "  silent            \(.silent)",
    ( if (.bySeverity | length) > 0 then "", "by severity:",
        (.bySeverity | to_entries[] | "  \(.key | (. + "          ")[0:11]) \(.value.n) · addressed \(.value.addressed) · discussed \(.value.discussed) · silent \(.value.silent)")
      else empty end ),
    ( if .skipped > 0 then "", "(\(.skipped) PR(s) could not be read and are not counted)" else empty end ),
    "", "\"addressed\" means resolved or outdated; outdated can also mean an unrelated edit, so read it as likely, not proven."'
}

cmd_stats() {
  local as_json=false days=30 refresh=false cache report age
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) as_json=true; shift ;;
      --days) days="${2:-30}"; shift $(( $# > 1 ? 2 : 1 )) ;;
      --refresh) refresh=true; shift ;;
      *) shift ;;
    esac
  done
  case "$days" in ''|*[!0-9]*) days=30 ;; esac
  [ "$days" -lt 1 ] && days=1
  [ "$days" -gt 365 ] && days=365

  cache="$(stats_cache_path)"
  if [ "$refresh" != true ] && [ -f "$cache" ]; then
    age=$(( $(now_epoch) - $(jq -r '.at // 0' "$cache" 2>/dev/null || echo 0) ))
    if jq -e --argjson d "$days" '.days == $d' "$cache" >/dev/null 2>&1 && [ "$age" -lt "$STATS_TTL_SECS" ]; then
      report="$(cat "$cache")"
      if [ "$as_json" = true ]; then printf '%s\n' "$report"; else stats_print "$report"; fi
      return 0
    fi
  fi

  if ! engine_auth_lite >/dev/null 2>&1; then
    if [ "$as_json" = true ]; then printf '{"error":"not authenticated"}\n'; else echo "not signed in to GitHub — run: gh auth login" >&2; fi
    return 1
  fi
  if ! report="$(stats_collect "$days")" || [ -z "$report" ]; then
    if [ "$as_json" = true ]; then printf '{"error":"could not read any review threads from GitHub"}\n'
    else echo "could not read any review threads from GitHub" >&2; fi
    return 1
  fi
  # A partial read would understate every number and then sit in the cache for hours.
  if [ "$(printf '%s' "$report" | jq -r '.skipped')" = "0" ]; then
    goblin_ensure_dirs
    printf '%s' "$report" | atomic_write "$cache"
  fi
  if [ "$as_json" = true ]; then printf '%s\n' "$report"; else stats_print "$report"; fi
}
