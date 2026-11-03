#!/usr/bin/env bash
# insights.sh — what this Mac's Goblin actually does, in one place.
#
#   goblin insights [--json] [--days N]
#
# Built only from local files: events.jsonl (every review outcome), usage.log (every
# command and screen used, see telemetry.sh), the config, and the cached `goblin stats`
# numbers (how posted findings fared). Nothing is fetched or sent. The fleet-wide
# version of this, across every install that shares counts, is scripts/fleet-stats.sh.
#
# It answers: which models and efforts run, how often they fail and why, what the
# findings are worth, which settings are off their defaults, and which commands and
# screens are used or never touched (the pruning list).

# Everything the app can show or do, so "never used" can be listed, not guessed.
INSIGHTS_KNOWN_UI="popover tab.waiting tab.recent quick window.review window.settings
settings.general settings.reviewer settings.repos settings.team settings.behaviour
settings.notifications settings.health settings.about"

cmd_insights() {
  local json=false days=30
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=true; shift ;;
      --days) days="${2:-30}"; shift $(( $# > 1 ? 2 : 1 )) ;;
      *) echo "usage: $GOBLIN_SLUG insights [--json] [--days N]" >&2; return 2 ;;
    esac
  done
  printf '%s' "$days" | grep -qE '^[0-9]{1,3}$' && [ "$days" -ge 1 ] || days=30
  local since=$(( $(now_epoch) - days * 86400 ))

  local events='[]' usage='{}' stats='{}' defaults current
  [ -f "$EVENTS" ] && events="$(jq -c --argjson s "$since" 'select(.at >= $s)' "$EVENTS" 2>/dev/null | jq -sc '.' 2>/dev/null)"
  [ -n "$events" ] || events='[]'
  usage="$(usage_counts "$since")"
  [ -f "$GOBLIN_HOME/stats.json" ] && stats="$(jq -c '.' "$GOBLIN_HOME/stats.json" 2>/dev/null || echo '{}')"
  defaults="$(goblin_default_config | jq -c '.')"
  current="$(cfg_read | jq -c '.')"

  local out
  out="$(jq -n --argjson ev "$events" --argjson usage "$usage" --argjson stats "$stats" \
      --argjson def "$defaults" --argjson cur "$current" --argjson days "$days" \
      --arg known "$INSIGHTS_KNOWN_UI" --arg version "$GOBLIN_VERSION" '
    def pct(a; b): if b > 0 then ((a * 1000 / b) | round / 10) else null end;
    ($ev | map(select(.status == "posted" or .status == "previewed" or .status == "failed"))) as $runs |
    {
      version: $version, days: $days,
      reviews: {
        total: ($runs | length),
        posted: ($runs | map(select(.status == "posted")) | length),
        previewed: ($runs | map(select(.status == "previewed")) | length),
        failed: ($runs | map(select(.status == "failed")) | length),
        skipped: ($ev | map(select(.status == "skipped")) | length),
        spendUsd: ($runs | map(.costUsd // 0) | add // 0)
      },
      byModel: ($runs | group_by([.provider, .model, (.effort // "")]) | map({
        provider: .[0].provider, model: .[0].model, effort: (.[0].effort // ""),
        reviews: length,
        failed: (map(select(.status == "failed")) | length),
        failRatePct: pct(map(select(.status == "failed")) | length; length),
        spendUsd: (map(.costUsd // 0) | add // 0)
      }) | sort_by(-.reviews)),
      failures: ($runs | map(select(.status == "failed")) | group_by([.provider, .reason])
                 | map({provider: .[0].provider, kind: .[0].reason, n: length}) | sort_by(-.n)),
      skipReasons: ($ev | map(select(.status == "skipped") | (.reason // "" | sub(":.*"; "")))
                    | group_by(.) | map({reason: .[0], n: length}) | sort_by(-.n)),
      repos: ($runs | group_by(.repo) | map({repo: .[0].repo, reviews: length}) | sort_by(-.reviews)),
      # how the findings posted on GitHub fared (the cached `goblin stats` sweep)
      findings: ($stats | {total: (.findings // null), addressed: (.addressed // null),
                           discussed: (.discussed // null), silent: (.silent // null),
                           addressedPct: (if (.addressedRate // null) == null then null else ((.addressedRate * 1000 | round) / 10) end)}),
      # settings that differ from the defaults (paths flattened; values only for scalars)
      changedSettings: ([ $cur | paths(scalars) as $p
                          | select(($p | map(tostring) | join(".")) | test("^(identity|repos|fleet|providers\\.[a-z]+\\.bin|setupComplete|lastRepo|snoozeUntil|refsForbiddenAt|failuresDismissedAt|schemaVersion)") | not)
                          | {key: ($p | map(tostring) | join(".")), value: ($cur | getpath($p)), default: ($def | getpath($p))}
                          | select(.default != null and .value != .default) ]),
      usage: ($usage | to_entries | sort_by(-.value) | map({name: .key, n: .value})),
      unusedScreens: [ $known | split("\\s+"; null)[] | select(length > 0) | select(($usage["ui." + .] // 0) == 0) ]
    }')" || { echo "could not read the local history" >&2; return 1; }

  if [ "$json" = true ]; then printf '%s\n' "$out"; return 0; fi
  printf '%s' "$out" | jq -r '
    "\(.days) days on \(.version)",
    "  reviews: \(.reviews.total) (\(.reviews.posted) posted, \(.reviews.previewed) previewed, \(.reviews.failed) failed), \(.reviews.skipped) skipped, $\(.reviews.spendUsd)",
    "",
    "models:",
    (.byModel[] | "  \(.provider)/\(.model)\(if .effort != "" then " · " + .effort else "" end): \(.reviews) reviews, \(.failed) failed\(if .failRatePct then " (\(.failRatePct)%)" else "" end)"),
    (if (.failures | length) > 0 then "", "failures:", (.failures[] | "  \(.provider) \(.kind): \(.n)") else empty end),
    (if (.skipReasons | length) > 0 then "", "skipped because:", (.skipReasons[] | "  \(.reason): \(.n)") else empty end),
    (if .findings.total then "", "findings on GitHub: \(.findings.total), \(.findings.addressedPct)% likely addressed, \(.findings.discussed) discussed, \(.findings.silent) silent" else "", "findings on GitHub: run `goblin stats` once to measure them" end),
    "", "settings changed from default:",
    (if (.changedSettings | length) == 0 then "  none" else (.changedSettings[] | "  \(.key) = \(.value) (default \(.default))") end),
    "", "most used:", (.usage[:12][] | "  \(.name): \(.n)"),
    "", "screens never opened: \(if (.unusedScreens | length) == 0 then "none" else (.unusedScreens | join(", ")) end)"'
}
