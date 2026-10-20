# fleet_test.sh — sourced by run.sh (needs eq, ROOT). `goblin fleet status` and the
# notification payload. The `t` registrations live in run.sh, after the source line.

fleet_env() {
  GOBLIN_HOME="$(mktemp -d)"; export GOBLIN_HOME
  export GOBLIN_APP="$ROOT"
  export GOBLIN_PATH_FIRST="$ROOT/tests/fixtures/fleet/bin:$ROOT/tests/fixtures/bin"
  export FLEET_FAKE_LOG="$GOBLIN_HOME/gh.log" FLEET_FAKE_DIR="$GOBLIN_HOME/fake"
  unset FLEET_FAKE_OFFLINE FLEET_FAKE_NOAUTH
  : > "$FLEET_FAKE_LOG"; mkdir -p "$FLEET_FAKE_DIR"
  cat > "$GOBLIN_HOME/config.json" <<JSON
{"schemaVersion":2,"identity":{"githubLogin":"me"},"provider":"claude","setupComplete":true,
 "intervalSeconds":300,"fleet":["me","alice","bob","carol"],
 "repos":[{"slug":"acme/widgets","enabled":true},{"slug":"acme/paused","enabled":false}]}
JSON
  G="$ROOT/bin/goblin"
  local now; now="$(date +%s)"
  iso() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }
  # alice is mid-review of #12; bob's claim is two days old (a crash), adopted
  jq -n --arg a "refs/goblin/meta/pr-12/abc123/$((now - 60))-alice" \
        --arg b "refs/goblin/meta/pr-7/def456/$((now - 172800))-bob.adopted" \
        '[{ref:$a},{ref:$b},{ref:"refs/goblin/meta/garbage"}]' > "$FLEET_FAKE_DIR/refs.json"
  jq -n --arg t1 "$(iso $((now - 7200)))" --arg t2 "$(iso $((now - 86400)))" '[
    {user:{login:"alice"}, created_at:$t1, pull_request_url:"https://api.github.com/repos/acme/widgets/pulls/10",
     body:"x <!-- goblin:finding {\"id\":\"a\"} -->"},
    {user:{login:"Bob"}, created_at:$t2, pull_request_url:"https://api.github.com/repos/acme/widgets/pulls/9",
     body:"<!-- bob:finding {\"id\":\"b\"} --> legacy prefix"},
    {user:{login:"mallory"}, created_at:$t1, pull_request_url:"https://api.github.com/repos/acme/widgets/pulls/10",
     body:"<!-- goblin:finding {} --> not on the team"},
    {user:{login:"carol"}, created_at:$t1, pull_request_url:"https://api.github.com/repos/acme/widgets/pulls/10",
     body:"a plain human comment"}]' > "$FLEET_FAKE_DIR/pulls-comments.json"
  jq -n --arg t "$(iso $((now - 7000)))" '[
    {user:{login:"alice"}, created_at:$t, issue_url:"https://api.github.com/repos/acme/widgets/issues/10",
     body:"<!-- goblin:intent {} -->"}]' > "$FLEET_FAKE_DIR/issues-comments.json"
  printf '{"lastRunStarted":%s,"lastRunFinished":%s}\n' "$((now - 40))" "$((now - 30))" > "$GOBLIN_HOME/status.json"
}
fleet_env_done() { rm -rf "$GOBLIN_HOME"; unset GOBLIN_PATH_FIRST FLEET_FAKE_OFFLINE FLEET_FAKE_NOAUTH; }

test_fleet_status_reads_what_each_goblin_left() {
  fleet_env
  local out m
  out="$("$G" fleet status --json 2>/dev/null)"
  eq "true" "$(printf '%s' "$out" | jq -r .ok)" || { echo "$out"; return 1; }
  eq "alice,bob,carol,me" "$(printf '%s' "$out" | jq -r '[.members[].login] | join(",")')" || return 1
  m() { printf '%s' "$out" | jq -c --arg l "$1" ".members[] | select(.login == \$l) | $2"; }
  eq '"active"' "$(m alice .status)"                  || return 1
  eq '[12]'     "$(m alice '[.reviewing[].pr]')"     || return 1
  eq '[10]'     "$(m alice '[.recent[].pr]')"        || { echo "finding + intent on one PR is one review"; return 1; }
  eq '"seen"'   "$(m bob .status)"                   || return 1
  eq '[]'       "$(m bob .reviewing)"                || { echo "a two-day-old claim is not a review in progress"; return 1; }
  eq '[9]'      "$(m bob '[.recent[].pr]')"          || { echo "legacy markers and login case must still count"; return 1; }
  eq '"unknown"' "$(m carol .status)"                || { echo "an unmarked comment is not the Goblin"; return 1; }
  eq 'true'     "$(m me .me)"                        || return 1
  eq '"active"' "$(m me .status)"                    || { echo "this machine's own scheduler run counts"; return 1; }
  printf '%s' "$out" | jq -e '[.members[].login] | index("mallory") | not' >/dev/null \
    || { echo "a marker from outside the fleet made someone a member"; return 1; }
  grep -q 'acme/paused' "$FLEET_FAKE_LOG" && { echo "read a paused repo"; return 1; }
  grep -q '^WRITE' "$FLEET_FAKE_LOG" && { echo "fleet status wrote to GitHub"; return 1; }
  [ -s "$GOBLIN_HOME/fleet-status.json" ] || { echo "not cached"; return 1; }
  # the text form works too
  "$G" fleet status 2>/dev/null | grep -q '^alice  active' || return 1
  fleet_env_done
}

test_fleet_status_cache_offline_and_no_fleet() {
  fleet_env
  "$G" fleet status --json >/dev/null 2>&1
  # within the TTL the cache answers without calling GitHub
  : > "$FLEET_FAKE_LOG"
  "$G" fleet status --json >/dev/null 2>&1
  grep -q 'matching-refs\|comments' "$FLEET_FAKE_LOG" && { echo "the cache was ignored"; return 1; }
  # offline: --refresh falls back to the last answer, marked stale
  local out
  out="$(FLEET_FAKE_OFFLINE=1 "$G" fleet status --json --refresh 2>/dev/null)"; eq 0 "$?" || return 1
  eq "true" "$(printf '%s' "$out" | jq -r '.ok and .stale')" || { echo "$out"; return 1; }
  # offline with nothing cached: an honest error, as JSON, exit 0
  rm -f "$GOBLIN_HOME/fleet-status.json"
  out="$(FLEET_FAKE_OFFLINE=1 "$G" fleet status --json 2>/dev/null)"; eq 0 "$?" || return 1
  eq "unreachable" "$(printf '%s' "$out" | jq -r .error)" || { echo "$out"; return 1; }
  [ -e "$GOBLIN_HOME/fleet-status.json" ] && { echo "cached a failure"; return 1; }
  out="$(FLEET_FAKE_NOAUTH=1 "$G" fleet status --json 2>/dev/null)"
  eq "not_authenticated" "$(printf '%s' "$out" | jq -r .error)" || { echo "$out"; return 1; }
  # a cache made for another team is not reused
  "$G" fleet status --json >/dev/null 2>&1
  jq '.fleet = ["me","dave"]' "$GOBLIN_HOME/config.json" > "$GOBLIN_HOME/c.t" && mv "$GOBLIN_HOME/c.t" "$GOBLIN_HOME/config.json"
  eq "dave,me" "$("$G" fleet status --json 2>/dev/null | jq -r '[.members[].login] | join(",")')" || return 1
  # no fleet: nothing to ask GitHub
  jq '.fleet = []' "$GOBLIN_HOME/config.json" > "$GOBLIN_HOME/c.t" && mv "$GOBLIN_HOME/c.t" "$GOBLIN_HOME/config.json"
  : > "$FLEET_FAKE_LOG"
  out="$("$G" fleet status --json 2>/dev/null)"
  eq "true 0" "$(printf '%s' "$out" | jq -r '"\(.ok) \(.members | length)"')" || { echo "$out"; return 1; }
  [ -s "$FLEET_FAKE_LOG" ] && { echo "asked GitHub with no fleet"; return 1; }
  fleet_env_done
}

test_notify_payload_names_the_job_and_kind() {
  setup
  local p
  GOBLIN_JOB_ID="j1700000000-12345"
  p="$(notify_payload "T" "#5 is ready" "Glass" ready)"
  eq "ready j1700000000-12345 #5 is ready" "$(printf '%s' "$p" | jq -r '"\(.kind) \(.job) \(.message)"')" || return 1
  # no job context: no job key at all, rather than an empty one
  GOBLIN_JOB_ID=""
  p="$(notify_payload "T" "m" "" posted)"
  eq "posted false" "$(printf '%s' "$p" | jq -r '"\(.kind) \(has("job"))"')" || return 1
  # something that is not a job id never reaches the app
  GOBLIN_JOB_ID="../../etc"
  p="$(notify_payload "T" "m" "" ready)"
  eq "false" "$(printf '%s' "$p" | jq -r 'has("job")')" || return 1
  GOBLIN_JOB_ID=""
  # the finished-preview banner says "ready", gated on the same switch as "posted"
  grep -q 'notify posted .*is ready to read.* ready$' "$ROOT/lib/engine.sh" \
    || { echo "the ready banner is not marked as kind ready"; return 1; }
  teardown
}
