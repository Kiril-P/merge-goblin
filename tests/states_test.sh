# states_test.sh — sourced by run.sh. The unhappy paths: what a failure is called,
# what it does to GitHub, usage limits and fallbacks, and what the panel says about
# a pause. The `t` registrations live in run.sh, after the line sourcing this.

test_failures_are_classified_not_other() {
  setup
  . "$ROOT/lib/providers.sh" 2>/dev/null
  local raw="$GOBLIN_HOME/raw"; mkdir -p "$raw"
  # cursor dropping its connection: the commonest real failure, and it used to be "other"
  printf 'Connection lost, reconnecting to https://agentn.example (attempt 1)...\nRetry attempt 1...\n' > "$raw/stderr.txt"
  eq transient "$(provider_classify_error "$(provider_error_text "$raw")")" || return 1
  eq "Retry attempt 1..." "$(provider_error_line "$raw")" || return 1
  # claude reports a usage limit as an is_error result, with nothing on stderr
  : > "$raw/stderr.txt"
  echo '{"is_error":true,"result":"Claude AI usage limit reached|1792670400","duration_ms":4290}' > "$raw/stdout.json"
  eq quota "$(provider_classify_error "$(provider_error_text "$raw")")" || return 1
  # a model that is TALKING about rate limits is not rate limited, and a 4290 is not a 429
  echo '{"is_error":false,"result":"This PR adds a rate limit and a quota check","duration_ms":4290}' > "$raw/stdout.json"
  eq other "$(provider_classify_error "$(provider_error_text "$raw")")" || return 1
  rm -f "$raw/stdout.json"
  # codex reports errors as stream events
  printf '%s\n' '{"type":"item.completed","item":{"text":"checks the rate limit"}}' \
    '{"type":"turn.failed","error":{"message":"You have hit your usage limit"}}' > "$raw/stdout.jsonl"
  eq quota "$(provider_classify_error "$(provider_error_text "$raw")")" || return 1
  eq auth  "$(provider_classify_error "Not logged in · Please run /login")" || return 1
  eq quota "$(provider_classify_error "HTTP 429 Too Many")" || return 1
  eq transient "$(provider_classify_error "upstream returned 503")" || return 1
  eq other "$(provider_classify_error "exit status 1")" || return 1
  # and every kind has words, so nothing ever reads "other"
  eq "lost the connection to Cursor" "$(failure_words transient cursor)" || return 1
  eq "the AI stopped with an error" "$(failure_words other "")" || return 1
  eq "Codex hit its usage limit" "$(failure_words quota codex)" || return 1
  teardown
}

test_a_usage_limit_rests_the_provider() {
  setup
  . "$ROOT/lib/providers.sh" 2>/dev/null
  providers_load() { :; }
  provider_claude_probe() { echo '{"available":true,"authed":true}'; }
  provider_codex_probe()  { echo '{"available":true,"authed":true}'; }
  provider_cursor_probe() { echo '{"available":false,"authed":false}'; }
  cfg_set '.provider = "claude" | .providerFallback = []'
  local now until; now="$(now_epoch)"
  # the reset the CLI names is used when it is believable…
  until="$(provider_cooldown_set claude "Claude AI usage limit reached|$((now + 1800))")"
  eq "$((now + 1800))" "$until" || return 1
  provider_cooling claude || { echo "not resting after a usage limit"; return 1; }
  # …and an hour otherwise
  until="$(provider_cooldown_set codex "usage limit")"
  [ "$until" -ge $((now + 3590)) ] && [ "$until" -le $((now + 3610)) ] || { echo "until=$until"; return 1; }
  provider_cooldown_clear codex
  # resting with no fallback: nothing to pick, unless a person asked
  providers_pick >/dev/null && { echo "picked a resting provider"; return 1; }
  eq claude "$(providers_pick --allow-cooling)" || return 1
  # with a fallback, the fallback reviews meanwhile
  cfg_set '.providerFallback = ["cursor","codex"]'
  eq codex "$(providers_pick)" || return 1
  provider_cooldown_clear claude
  eq claude "$(providers_pick)" || return 1
  teardown
}

_states_engine() {
  . "$ROOT/lib/diff.sh" 2>/dev/null; . "$ROOT/lib/github.sh" 2>/dev/null; . "$ROOT/lib/engine.sh" 2>/dev/null
  mk_fake_gh
  providers_load() { :; }
  provider_claude_probe() { echo '{"available":true,"authed":true}'; }
  provider_codex_probe()  { echo '{"available":true,"authed":true}'; }
  GOBLIN_LOGIN="me"; ONLY_PR=""; FORCE=false; DRY_RUN=false; PREVIEW=false; ENGINE_STOP=""
  REVIEWED=""; REVIEWED_WITH=""
  engine_review_pr() { REVIEWED="$2"; REVIEWED_WITH="$7"; return 0; }
  gh_prior_review() { :; }; engine_budget_ok() { return 0; }; skip_check() { return 1; }
  gh_pr_is_open() { return 0; }; claim_try() { return 0; }; claim_sweep() { :; }
  claim_eligible() { echo me; }; claim_assignee() { echo me; }
  notify() { NOTIFIED="$2|$3"; }
}

_states_entry() {
  jq -nc '{number:7, head:"abc123", draft:false, title:"T", url:"u", base:"main", author:"alice",
           updatedAt:0, requested:["me"]}'
}

test_a_resting_provider_stops_or_falls_back() {
  setup; _states_engine
  cfg_set '.provider = "claude" | .providerFallback = []'
  provider_cooldown_set claude "usage limit" >/dev/null
  engine_pr acme/w "$(_states_entry)" claude
  eq "" "$REVIEWED" || { echo "reviewed with a resting provider"; return 1; }
  eq quota "$ENGINE_STOP" || { echo "the run would fail every PR in turn"; return 1; }
  eq claude "$ENGINE_STOP_PROVIDER" || return 1
  # a repo whose own provider is resting is reviewed by the run's provider instead
  ENGINE_STOP=""; ENGINE_STOP_PROVIDER=""
  cfg_set '.repos = [{"slug":"acme/w","provider":"claude"}]'
  engine_repo_provider acme/w codex
  eq codex "$ENGINE_REPO_PROVIDER" || { echo "used a resting repo provider"; return 1; }
  cfg_set '.repos = []'
  # nothing was recorded against the PR: the limit is not its fault
  [ -s "$(attempt_file)" ] && jq -e 'length > 0' "$(attempt_file)" >/dev/null && { echo "PR blamed"; return 1; }
  ENGINE_STOP=""
  cfg_set '.providerFallback = ["codex"]'
  engine_pr acme/w "$(_states_entry)" claude
  eq 7 "$REVIEWED" || return 1
  eq codex "$REVIEWED_WITH" || { echo "the fallback did not take over"; return 1; }
  eq "" "$ENGINE_STOP" || return 1
  teardown
}

test_a_usage_limit_mid_review_uses_the_fallback() {
  setup; _states_engine
  local w="$GOBLIN_HOME/work"; mkdir -p "$w/raw"
  CALLS=""
  findings_run() {
    CALLS="$CALLS $1"
    case "$1" in
      claude) GOBLIN_P_ERRKIND=quota; GOBLIN_P_ERRMSG="Claude AI usage limit reached"; return 1 ;;
      codex)  return 0 ;;
    esac
  }
  # no fallback: the provider rests, and a scheduled run stops
  cfg_set '.provider = "claude" | .providerFallback = []'
  engine_model_run claude "$w" "$w" 7 && { echo "a usage limit counted as a review"; return 1; }
  eq quota "$ENGINE_MODEL_KIND" || return 1
  eq quota "$ENGINE_STOP" || return 1
  provider_cooling claude || return 1
  # a fallback reviews the same PR straight away
  provider_cooldown_clear claude; ENGINE_STOP=""; CALLS=""
  cfg_set '.providerFallback = ["codex"]'
  engine_model_run claude "$w" "$w" 7 || { echo "the fallback did not review it"; return 1; }
  eq " claude codex" "$CALLS" || return 1
  eq codex "$ENGINE_MODEL_PROVIDER" || return 1
  eq "" "$ENGINE_MODEL_KIND" || return 1
  eq "" "$ENGINE_STOP" || return 1
  # any other failure is not retried elsewhere
  findings_run() { CALLS="$CALLS $1"; GOBLIN_P_ERRKIND=transient; return 1; }
  CALLS=""; provider_cooldown_clear claude
  engine_model_run claude "$w" "$w" 7 && return 1
  eq " claude" "$CALLS" || return 1
  eq transient "$ENGINE_MODEL_KIND" || return 1
  provider_cooling claude && { echo "a network blip rested the provider"; return 1; }
  teardown
}

test_a_failure_says_what_and_when() {
  setup; _states_engine
  GH_LOG="$GOBLIN_HOME/gh.log"; export GH_LOG; : > "$GH_LOG"
  JOBS_DIR="$GOBLIN_HOME/jobs"; mkdir -p "$JOBS_DIR/j1-1"
  echo '{"id":"j1-1","phase":"reviewing"}' > "$JOBS_DIR/j1-1/job.json"
  GOBLIN_JOB_ID=j1-1; GOBLIN_JOB_DIR="$JOBS_DIR/j1-1"
  # scheduled: the check stays pending, with what happened and when it is retried
  engine_fail acme/w 7 abc123 T u transient cursor m 0 "Connection lost, reconnecting"
  grep -q 'state=pending' "$GH_LOG" || { echo "got: $(cat "$GH_LOG")"; return 1; }
  grep -q "description=Couldn't finish: lost the connection to Cursor. Trying again around [0-9][0-9]:[0-9][0-9]." "$GH_LOG" \
    || { echo "got: $(cat "$GH_LOG")"; return 1; }
  grep -q 'state=error' "$GH_LOG" && { echo "a teammate's PR went red for our failure"; return 1; }
  case "$NOTIFIED" in "Couldn't review #7|Lost the connection to Cursor. Trying again around "*) ;;
    *) echo "notified: $NOTIFIED"; return 1 ;; esac
  eq transient "$(job_get j1-1 error)" || return 1
  eq "Connection lost, reconnecting" "$(job_get j1-1 errorRaw)" || return 1
  job_get j1-1 errorDetail | grep -q '^Lost the connection to Cursor. The Goblin tries again around' || return 1
  # a preview never touched GitHub, so its failure must not either
  : > "$GH_LOG"; PREVIEW=true
  engine_fail acme/w 8 def456 T u other claude m 0 "boom"
  [ -s "$GH_LOG" ] && { echo "a failed preview posted to GitHub: $(cat "$GH_LOG")"; return 1; }
  PREVIEW=false
  # a usage limit is not held against the PR
  rm -f "$(attempt_file)"
  engine_fail acme/w 9 aaa111 T u quota claude m 0 "limit"
  [ -f "$(attempt_file)" ] && jq -e 'has("9:aaa111")' "$(attempt_file)" >/dev/null && { echo "quota counted against the PR"; return 1; }
  GOBLIN_JOB_ID=""; GOBLIN_JOB_DIR=""
  teardown
}

test_pauses_say_how_much_and_until_when() {
  setup
  . "$ROOT/lib/inbox.sh"; . "$ROOT/lib/attempts.sh"
  local real_home="$HOME"
  HOME="$GOBLIN_HOME/home"; export HOME
  mkdir -p "$HOME/.config/gh" "$HOME/Library/LaunchAgents"
  printf 'github.com:\n    user: me\n' > "$HOME/.config/gh/hosts.yml"
  AGENT_PLIST="$HOME/Library/LaunchAgents/test.plist"; : > "$AGENT_PLIST"
  LC_FAKE_RUNNING=1; export LC_FAKE_RUNNING; unset LC_FAKE_DISABLED
  cfg_set --arg l me '.identity.githubLogin = $l | .setupComplete = true | .maxReviewsPerDay = 20 | .budgetCapUsd = 10'
  _ui() { ui_state_write; jq -r "$1" "$UISTATE"; }
  _fin() { HOME="$real_home"; export HOME; unset LC_FAKE_RUNNING; }

  status_set '{"state":"paused","pausedReason":"quota"}'
  case "$(_ui .bar.tooltip)" in "daily review limit reached · 0 of 20 today · resumes at midnight") ;;
    *) echo "got: $(_ui .bar.tooltip)"; _fin; return 1 ;; esac
  status_set '{"state":"paused","pausedReason":"budget"}'
  case "$(_ui .bar.tooltip)" in "daily budget spent · \$0 of \$10 · resumes at midnight") ;;
    *) echo "got: $(_ui .bar.tooltip)"; _fin; return 1 ;; esac
  status_set "$(jq -nc --argjson u "$(( $(now_epoch) + 600 ))" '{state:"paused",pausedReason:"provider_quota",pausedProvider:"claude",resumeAt:$u}')"
  eq quota "$(_ui .bar.glyph)" || { _fin; return 1; }
  _ui .bar.tooltip | grep -qE '^Claude hit its usage limit · trying again (tomorrow )?at [0-9]{2}:[0-9]{2}$' \
    || { echo "got: $(_ui .bar.tooltip)"; _fin; return 1; }
  status_set '{"state":"idle","pausedReason":""}'
  cfg_set ".snoozeUntil = $(( $(now_epoch) + 3600 ))"
  _ui .bar.tooltip | grep -qE '^snoozed until [0-9]{2}:[0-9]{2}$' || { echo "got: $(_ui .bar.tooltip)"; _fin; return 1; }
  cfg_set '.snoozeUntil = 0'

  # no problem, no banner; a red icon always comes with one
  eq idle "$(_ui .bar.glyph)" || { _fin; return 1; }
  eq null "$(_ui .bar.problem)" || { _fin; return 1; }
  status_set '{"doctor":{"fail":1,"warn":0,"at":0}}'
  eq error "$(_ui .bar.glyph)" || { _fin; return 1; }
  eq health "$(_ui .bar.problem.action)" || { _fin; return 1; }
  eq "A health check is failing" "$(_ui .bar.problem.title)" || { _fin; return 1; }
  status_set '{"doctor":{"fail":0,"warn":0,"at":0}}'
  # two failures today, explained in words
  events_append failed 12 T u 0 transient acme/w cursor m
  events_append failed 13 T u 0 transient acme/w cursor m
  eq error "$(_ui .bar.glyph)" || { _fin; return 1; }
  eq "#13: lost the connection to Cursor." "$(_ui .bar.problem.detail)" || { _fin; return 1; }
  _fin; teardown
}
