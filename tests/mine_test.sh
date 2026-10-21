# mine_test.sh — sourced by run.sh. Reviewing your own pull requests (reviewMine).
# The `t` registrations live in run.sh, after the line sourcing this.

# engine_pr with everything past the gates stubbed: records whether a review started.
_mine_engine() {
  . "$ROOT/lib/diff.sh" 2>/dev/null; . "$ROOT/lib/github.sh" 2>/dev/null; . "$ROOT/lib/engine.sh" 2>/dev/null
  mk_fake_gh
  GOBLIN_LOGIN="Me"; ONLY_PR=""; FORCE=false; DRY_RUN=true
  REVIEWED=""; MINE_SEEN=""
  engine_review_pr() { REVIEWED="$2"; MINE_SEEN="$ENGINE_MINE"; return 0; }
  gh_prior_review() { :; }
  engine_budget_ok() { return 0; }
  skip_check() { return 1; }
}

_mine_entry() {  # <author> <draft>
  jq -nc --arg a "$1" --argjson d "${2:-false}" \
    '{number:7, head:"abc123", draft:$d, title:"T", url:"u", base:"main", author:$a,
      updatedAt:0, requested:[]}'
}

test_own_prs_are_left_alone_unless_asked() {
  setup; _mine_engine
  engine_pr acme/w "$(_mine_entry me)" claude
  eq "" "$REVIEWED" || { echo "reviewMine off still reviewed your own PR"; return 1; }
  teardown
}

test_own_prs_are_reviewed_when_on() {
  setup; _mine_engine
  cfg_set '.reviewMine = "hold"'
  # case-insensitive: GitHub logins are
  engine_pr acme/w "$(_mine_entry me)" claude
  eq "7" "$REVIEWED"    || { echo "own PR not reviewed"; return 1; }
  eq "hold" "$MINE_SEEN" || return 1
  # someone else's PR nobody asked you about is still not yours
  REVIEWED=""
  engine_pr acme/w "$(_mine_entry alice)" claude
  eq "" "$REVIEWED" || { echo "reviewMine reviewed a PR you were not asked on"; return 1; }
  eq "" "$ENGINE_MINE" || { echo "mine mode leaked into the next PR"; return 1; }
  teardown
}

test_own_drafts_only_when_asked() {
  setup; _mine_engine
  cfg_set '.reviewMine = "post"'
  engine_pr acme/w "$(_mine_entry me true)" claude
  eq "" "$REVIEWED" || { echo "draft reviewed without reviewMineDrafts"; return 1; }
  cfg_set '.reviewMineDrafts = true'
  engine_pr acme/w "$(_mine_entry me true)" claude
  eq "7" "$REVIEWED" || { echo "draft not reviewed with reviewMineDrafts"; return 1; }
  teardown
}

test_a_private_review_leaves_github_alone() {
  setup; _mine_engine
  GH_LOG="$GOBLIN_HOME/gh.log"; export GH_LOG; : > "$GH_LOG"
  ENGINE_MINE=hold
  gh_status acme/w abc123 pending "reviewing"
  [ -s "$GH_LOG" ] && { echo "a commit status was posted for a private review"; return 1; }
  local n="$GOBLIN_HOME/n.json"; echo '{"findings":[]}' > "$n"
  engine_should_hold "$n" || { echo "a private review would have posted (autoPost=always)"; return 1; }
  ENGINE_MINE=post
  engine_should_hold "$n" && { echo "post mode should follow autoPost"; return 1; }
  ENGINE_MINE=""
  teardown
}

test_own_pr_verdict_is_always_a_comment() {
  setup
  . "$ROOT/lib/findings.sh" 2>/dev/null
  GOBLIN_LOGIN="Me"
  cfg_set '.verdictMode = "request-changes"'
  local n="$GOBLIN_HOME/n.json"; echo '{"findings":[{"severity":"blocker"}]}' > "$n"
  eq "REQUEST_CHANGES" "$(findings_verdict "$n" alice)" || return 1
  eq "COMMENT" "$(findings_verdict "$n" me)" || { echo "GitHub refuses request-changes on your own PR"; return 1; }
  teardown
}

test_a_newer_held_review_replaces_the_older() {
  setup
  . "$ROOT/lib/diff.sh" 2>/dev/null; . "$ROOT/lib/engine.sh" 2>/dev/null
  mk_fake_gh; notify() { :; }
  local w="$GOBLIN_HOME/work"; mkdir -p "$w"
  echo '{"summary":"s","findings":[]}' > "$w/norm.json"
  echo '[]' > "$w/addr.json"; echo '[{"path":"f","additions":1,"deletions":0}]' > "$w/files.json"
  echo '{"author":"me"}' > "$w/pr.json"; echo '[]' > "$GOBLIN_HOME/prior.json"
  ENGINE_HOLD_WHY="x"
  engine_hold "$w" acme/w 7 old1 main T u claude "$GOBLIN_HOME/prior.json" || return 1
  local first; first="$(ls "$JOBS_DIR")"
  sleep 1
  engine_hold "$w" acme/w 7 new2 main T u claude "$GOBLIN_HOME/prior.json" || return 1
  eq "discarded" "$(job_get "$first" phase)" || { echo "the older held review is still waiting"; return 1; }
  eq "1" "$(jq -s '[.[] | select(.phase == "ready")] | length' "$JOBS_DIR"/*/job.json)" || return 1
  teardown
}

test_commit_status_has_no_emoji() {
  setup
  . "$ROOT/lib/github.sh" 2>/dev/null
  mk_fake_gh
  GH_LOG="$GOBLIN_HOME/gh.log"; export GH_LOG; : > "$GH_LOG"
  gh_status a/b abc success "🔴 2 blocker · 🟡 1 risk · ⚪️ 3 nit · composer-2.5" "https://x"
  grep -q 'description=2 blocker · 1 risk · 3 nit · composer-2.5' "$GH_LOG" \
    || { echo "got: $(cat "$GH_LOG")"; return 1; }
  # GitHub's rule: nothing above U+FFFF
  LC_ALL=C grep -q $'\xf0' "$GH_LOG" && { echo "a 4-byte character reached GitHub"; return 1; }
  teardown
}

test_fixed_prior_is_kept_and_prompted() {
  setup
  . "$ROOT/lib/prompt.sh" 2>/dev/null
  # normalize keeps well-formed ids only
  local out; out="$(echo '{"summary":"s","findings":[],"fixed_prior":["a23f9e0f2eda","bad id; rm",7,"a23f9e0f2eda"]}' \
    | jq -c --argjson max 25 -f "$ROOT/share/jq/normalize.jq")"
  eq '["a23f9e0f2eda"]' "$(printf '%s' "$out" | jq -c .fixed_prior)" || return 1
  eq '[]' "$(echo '{"summary":"s","findings":[]}' | jq -c --argjson max 25 -f "$ROOT/share/jq/normalize.jq" | jq -c .fixed_prior)" || return 1
  # the model is shown the id it has to quote back
  echo '[{"id":"a23f9e0f2eda","severity":"blocker","path":"x.js","line":3,"title":"T"}]' > "$GOBLIN_HOME/p.json"
  prompt_prior_lines "$GOBLIN_HOME/p.json" | grep -q '^- \[a23f9e0f2eda\] blocker: x.js:3 — T$' \
    || { echo "got: $(prompt_prior_lines "$GOBLIN_HOME/p.json")"; return 1; }
  # the strict schema (codex) requires it, or codex would never send it
  jq -e '.required | index("fixed_prior")' "$ROOT/share/schema/findings.strict.schema.json" >/dev/null || return 1
  teardown
}
