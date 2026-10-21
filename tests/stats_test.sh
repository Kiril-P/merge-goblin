# stats_test.sh — sourced by run.sh (needs review_env, eq). `goblin stats`.
# The `t` registrations live in run.sh, right after the line that sources this file.

stats_events() {   # events.jsonl: 2 posted on one PR (dedupe), 1 old, 1 failed
  local now; now="$(date +%s)"
  {
    jq -nc --argjson at "$now" '{at:$at,number:5,status:"posted",repo:"acme/widgets",url:"https://github.com/acme/widgets/pull/5"}'
    jq -nc --argjson at "$((now - 60))" '{at:$at,number:5,status:"posted",repo:"acme/widgets"}'
    jq -nc --argjson at "$((now - 90 * 86400))" '{at:$at,number:3,status:"posted",repo:"acme/widgets"}'
    jq -nc --argjson at "$now" '{at:$at,number:9,status:"failed",repo:"acme/widgets"}'
  } > "$GOBLIN_HOME/events.jsonl"
}

test_stats_classifies_our_threads() {
  review_env
  stats_events
  local out
  out="$(REVIEW_FAKE_THREADS="$ROOT/tests/fixtures/review/threads.json" "$G" stats --json --days 30 2>/dev/null)"
  eq "1" "$(printf '%s' "$out" | jq '.prs')"             || { echo "$out"; return 1; }
  eq "4" "$(printf '%s' "$out" | jq '.findings')"        || { echo "$out"; return 1; }   # not alice's, not the unmarked one
  eq "2" "$(printf '%s' "$out" | jq '.addressed')"       || return 1   # resolved + outdated
  eq "1" "$(printf '%s' "$out" | jq '.discussed')"       || return 1   # the user replying as themselves counts
  eq "1" "$(printf '%s' "$out" | jq '.silent')"          || return 1
  eq "0.5" "$(printf '%s' "$out" | jq '.addressedRate')" || return 1
  eq "1" "$(printf '%s' "$out" | jq '.bySeverity.blocker.addressed')" || return 1
  eq "1" "$(printf '%s' "$out" | jq '.bySeverity.nit.silent')"        || return 1
  eq "0" "$(printf '%s' "$out" | jq '.skipped')"         || return 1
  review_env_done
}

test_stats_window_cache_and_failures() {
  review_env
  stats_events
  local out
  # a 120-day window picks up the old PR too
  out="$(REVIEW_FAKE_THREADS="$ROOT/tests/fixtures/review/threads.json" "$G" stats --json --days 120 2>/dev/null)"
  eq "2" "$(printf '%s' "$out" | jq '.looked')" || { echo "$out"; return 1; }
  # a good read is cached, and the cache answers without calling GitHub
  [ -s "$GOBLIN_HOME/stats.json" ] || { echo "a good read was not cached"; return 1; }
  : > "$REVIEW_FAKE_LOG"
  "$G" stats --json --days 120 >/dev/null 2>&1
  ! grep -q graphql "$REVIEW_FAKE_LOG" || { echo "the cache was ignored"; return 1; }
  # --refresh goes back to GitHub; when it cannot read ANY thread it fails and keeps the old cache
  local before; before="$(cat "$GOBLIN_HOME/stats.json")"
  "$G" stats --json --days 120 --refresh >/dev/null 2>&1; eq 1 "$?" || return 1
  eq "$before" "$(cat "$GOBLIN_HOME/stats.json")" || { echo "a failed read replaced the cache"; return 1; }
  # no events at all is an honest zero, not an error
  rm -f "$GOBLIN_HOME/events.jsonl" "$GOBLIN_HOME/stats.json"
  out="$("$G" stats --json 2>/dev/null)"
  eq "0" "$(printf '%s' "$out" | jq '.findings')" || return 1
  eq "null" "$(printf '%s' "$out" | jq '.addressedRate')" || return 1
  review_env_done
}
