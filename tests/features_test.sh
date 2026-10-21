# features_test.sh — sourced by run.sh (needs setup/teardown, review_env, mk_fake_gh, eq).
# Skip rules, declined findings, per-repo providers, codex confinement, pagination and
# `goblin stats --by`. The `t` registrations live in run.sh, after the line sourcing this.

# ------------------------------------------------------------- pagination ---
# Two pages exactly as `gh api --paginate` prints them: back to back, no wrapper.
_two_review_pages() {
  cat > "$GOBLIN_HOME/p1.json" <<J
[{"id":10,"body":"<!-- $GOBLIN_MARKER_NS:review {\"headSha\":\"old\"} -->","user":{"login":"me","type":"User"},"state":"COMMENTED","submitted_at":"2026-01-01T00:00:00Z","commit_id":"old"},
 {"id":11,"body":"lgtm","user":{"login":"bob","type":"User"},"state":"APPROVED","submitted_at":"2026-01-01T01:00:00Z","commit_id":"old"}]
J
  cat > "$GOBLIN_HOME/p2.json" <<J
[{"id":12,"body":"<!-- $GOBLIN_MARKER_NS:review {\"headSha\":\"new\"} -->","user":{"login":"me","type":"User"},"state":"COMMENTED","submitted_at":"2026-02-01T00:00:00Z","commit_id":"new"},
 {"id":13,"body":"again","user":{"login":"bob","type":"User"},"state":"COMMENTED","submitted_at":"2026-02-01T01:00:00Z","commit_id":"new"}]
J
  GH_PAGES="$GOBLIN_HOME/p1.json $GOBLIN_HOME/p2.json"; export GH_PAGES
}

test_pagination_reviews_are_one_answer() {
  setup
  . "$ROOT/lib/github.sh" 2>/dev/null
  mk_fake_gh; GOBLIN_LOGIN=me
  _two_review_pages
  # the latest review across BOTH pages, as one object (per-page --jq printed two)
  local prior; prior="$(gh_prior_review a/b 1)"
  eq "1" "$(printf '%s' "$prior" | jq -s 'length')" || { echo "got: $prior"; return 1; }
  eq "new" "$(printf '%s' "$prior" | jq -r '.m.headSha')" || return 1
  # one array of all four, and a human counted once
  gh_reviews_fetch a/b 1 "$GOBLIN_HOME/r.json" || return 1
  eq "4" "$(jq 'length' "$GOBLIN_HOME/r.json")" || return 1
  eq "bob" "$(gh_human_reviewers "$GOBLIN_HOME/r.json" | paste -sd, -)" || return 1
  unset GH_PAGES
  teardown
}

test_pagination_comments_are_one_answer() {
  setup
  . "$ROOT/lib/github.sh" 2>/dev/null
  mk_fake_gh; GOBLIN_LOGIN=me
  cat > "$GOBLIN_HOME/c1.json" <<J
[{"id":1,"user":{"login":"me"},"path":"a.js","line":1,"body":"<!-- $GOBLIN_MARKER_NS:finding {\"id\":\"one\",\"severity\":\"risk\"} -->\n🟡 **First**"},
 {"id":2,"user":{"login":"carol"},"path":"a.js","line":1,"body":"what about x?"}]
J
  cat > "$GOBLIN_HOME/c2.json" <<J
[{"id":3,"user":{"login":"me"},"path":"b.js","line":2,"body":"<!-- $GOBLIN_MARKER_NS:finding {\"id\":\"two\",\"severity\":\"nit\"} -->\n⚪ **Second**"},
 {"id":4,"user":{"login":"dave"},"path":"b.js","line":2,"body":"also y"}]
J
  GH_PAGES="$GOBLIN_HOME/c1.json $GOBLIN_HOME/c2.json"; export GH_PAGES
  local pf; pf="$(gh_prior_findings a/b 1)"
  eq "1" "$(printf '%s' "$pf" | jq -s 'length')" || { echo "several arrays: $pf"; return 1; }
  eq "one two" "$(printf '%s' "$pf" | jq -r '[.[].id] | join(" ")')" || return 1
  # others' comments from both pages (this one was already per-item, and must stay so)
  local others; others="$(gh_other_comments a/b 1)"
  printf '%s' "$others" | grep -q "@carol" || { echo "$others"; return 1; }
  printf '%s' "$others" | grep -q "@dave"  || { echo "$others"; return 1; }
  unset GH_PAGES
  teardown
}

test_pagination_issue_comments_are_one_answer() {
  setup
  . "$ROOT/lib/github.sh" 2>/dev/null; . "$ROOT/lib/render.sh"; . "$ROOT/lib/claim.sh" 2>/dev/null
  mk_fake_gh; GOBLIN_LOGIN=me
  echo '[{"id":5,"body":"hello","user":{"login":"x","type":"User"}}]' > "$GOBLIN_HOME/i1.json"
  cat > "$GOBLIN_HOME/i2.json" <<J
[{"id":77,"body":"<!-- $GOBLIN_MARKER_NS:intent {} -->","user":{"login":"me","type":"User"}},
 {"id":78,"body":"<!-- linear-linkback --> https://linear.app/x/issue/ABC-1 The real ticket text","user":{"login":"linear[bot]","type":"Bot"}},
 {"id":79,"body":"<!-- $GOBLIN_MARKER_NS:claim {} --> deadbeef","user":{"login":"me","type":"User"}}]
J
  GH_PAGES="$GOBLIN_HOME/i1.json $GOBLIN_HOME/i2.json"; export GH_PAGES
  # upsert lookup: one id, not "nothing from page one" + "77 from page two"
  eq "77" "$(gh_find_comment a/b 1 intent)" || return 1
  # the tracker linkback sits on page two and is included exactly once
  echo '{"body":"no link here"}' > "$GOBLIN_HOME/pr.json"
  gh_ticket_context a/b 1 "$GOBLIN_HOME/pr.json" "$GOBLIN_HOME/t.txt" >/dev/null
  eq "1" "$(grep -c 'The real ticket text' "$GOBLIN_HOME/t.txt")" || { cat "$GOBLIN_HOME/t.txt"; return 1; }
  # the claim arbitration: the lowest claim id across ALL pages wins. Page one has no
  # claim at all, which per page used to print "null" first and lose every claim.
  sleep() { :; }
  GH_POST_ID=79; export GH_POST_ID
  claim_try_comment a/b 1 deadbeef || { echo "won the claim but did not see it"; unset -f sleep; return 1; }
  unset -f sleep; unset GH_PAGES GH_POST_ID
  teardown
}

test_pagination_an_error_page_is_not_an_empty_list() {
  setup
  . "$ROOT/lib/github.sh" 2>/dev/null
  mk_fake_gh; GOBLIN_LOGIN=me
  echo '[{"id":1,"user":{"login":"me"},"body":"x"}]' > "$GOBLIN_HOME/ok.json"
  echo '{"message":"API rate limit exceeded"}' > "$GOBLIN_HOME/err.json"
  GH_PAGES="$GOBLIN_HOME/ok.json $GOBLIN_HOME/err.json"; export GH_PAGES
  gh_api_all "repos/a/b/pulls/1/comments" >/dev/null && { echo "an error page read as a list"; return 1; }
  gh_reviews_fetch a/b 1 "$GOBLIN_HOME/r.json" && { echo "reviews fetch accepted an error page"; return 1; }
  gh_prior_findings a/b 1 >/dev/null && { echo "prior findings accepted an error page"; return 1; }
  unset GH_PAGES
  teardown
}

test_stats_reads_every_page_of_threads() {
  review_env
  stats_events
  # Two GraphQL pages back to back, as `gh api graphql --paginate` prints them.
  local f="$GOBLIN_HOME/threads2.json"
  { cat "$ROOT/tests/fixtures/review/threads.json"
    cat <<'J'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"isResolved":false,"isOutdated":false,"comments":{"nodes":[
    {"author":{"login":"me"},"createdAt":"2026-01-01T00:00:00Z","body":"<!-- goblin:finding {\"v\":1,\"id\":\"f9\",\"severity\":\"risk\"} -->\n🟡 **Page two**"}]}}]}}}}}
J
  } > "$f"
  local out; out="$(REVIEW_FAKE_THREADS="$f" "$G" stats --json --days 30 --refresh 2>/dev/null)"
  eq "5" "$(printf '%s' "$out" | jq '.findings')" || { echo "$out"; return 1; }
  eq "2" "$(printf '%s' "$out" | jq '.silent')"   || return 1
  grep -q -- '--paginate' "$REVIEW_FAKE_LOG" || { echo "stats did not ask for every page"; return 1; }
  review_env_done
}

# ------------------------------------------------------------ stats --by ---
test_stats_by_severity_and_repo() {
  review_env
  stats_events
  local out
  out="$(REVIEW_FAKE_THREADS="$ROOT/tests/fixtures/review/threads.json" "$G" stats --json --by severity 2>/dev/null)"
  eq "severity" "$(printf '%s' "$out" | jq -r '.by')" || { echo "$out"; return 1; }
  # worst first, with all three outcomes per row
  eq "blocker,risk,convention,nit" "$(printf '%s' "$out" | jq -r '[.groups[].name] | join(",")')" || { echo "$out"; return 1; }
  eq "1" "$(printf '%s' "$out" | jq '.groups[0].addressed')" || return 1
  eq "1" "$(printf '%s' "$out" | jq '.groups[2].discussed')" || return 1
  eq "1" "$(printf '%s' "$out" | jq '.groups[3].silent')"    || return 1
  eq "1" "$(printf '%s' "$out" | jq '.groups[0].addressedRate')" || return 1
  # by repo, answered from the cache (no second trip to GitHub)
  : > "$REVIEW_FAKE_LOG"
  out="$("$G" stats --json --by repo 2>/dev/null)"
  ! grep -q graphql "$REVIEW_FAKE_LOG" || { echo "--by went back to GitHub"; return 1; }
  eq "acme/widgets" "$(printf '%s' "$out" | jq -r '.groups[0].name')" || { echo "$out"; return 1; }
  eq "4 2 1 1" "$(printf '%s' "$out" | jq -r '.groups[0] | "\(.n) \(.addressed) \(.discussed) \(.silent)"')" || return 1
  # the full report also carries the per-repo tally
  eq "4" "$("$G" stats --json 2>/dev/null | jq '.byRepo["acme/widgets"].n')" || return 1
  # plain text: a header and one row per group
  out="$("$G" stats --by severity 2>/dev/null)"
  printf '%s' "$out" | grep -q "by severity" || { echo "$out"; return 1; }
  printf '%s\n' "$out" | grep -qE '^  blocker +1 +1 +0 +0 +100%' || { echo "$out"; return 1; }
  "$G" stats --by nonsense >/dev/null 2>&1; eq 2 "$?" || return 1
  review_env_done
}

# ------------------------------------------------------- declined findings ---
test_declined_heuristic() {
  setup
  local f="$GOBLIN_HOME/c.json"
  cat > "$f" <<'J'
[{"id":1,"user":{"login":"me"},"path":"a.js","line":3,"body":"<!-- goblin:finding {\"id\":\"f1\",\"severity\":\"risk\"} -->\n🟡 risk **Unchecked null**\n\nbody"},
 {"id":2,"user":{"login":"alice"},"in_reply_to_id":1,"body":"This is intentional — won’t fix."},
 {"id":3,"user":{"login":"me"},"path":"b.js","line":null,"original_line":9,"body":"<!-- goblin:finding {\"id\":\"f2\",\"severity\":\"nit\"} -->\n⚪ nit **Typo**"},
 {"id":4,"user":{"login":"alice"},"in_reply_to_id":3,"body":"Not intentional, good catch!"},
 {"id":5,"user":{"login":"me"},"path":"c.js","line":1,"body":"<!-- goblin:finding {\"id\":\"f3\",\"severity\":\"blocker\"} -->\n🔴 **Leak**"},
 {"id":6,"user":{"login":"me"},"path":"d.js","line":1,"body":"<!-- goblin:finding {\"id\":\"f4\",\"severity\":\"risk\"} -->\n🟡 **Race**"},
 {"id":7,"user":{"login":"dependabot[bot]","type":"Bot"},"in_reply_to_id":6,"body":"by design"},
 {"id":8,"user":{"login":"me"},"path":"e.js","line":1,"body":"<!-- goblin:finding {\"id\":\"f5\",\"severity\":\"nit\"} -->\n⚪ **Name**"},
 {"id":9,"user":{"login":"me"},"in_reply_to_id":8,"body":"<!-- goblin:fixed {} -->\n✅ no longer flagged as of `abc` — intentional test"},
 {"id":10,"user":{"login":"me"},"path":"f.js","line":1,"body":"<!-- goblin:finding {\"id\":\"f6\",\"severity\":\"risk\"} -->\n🟡 **Retry**"},
 {"id":11,"user":{"login":"me"},"in_reply_to_id":10,"body":"wontfix, false positive"},
 {"id":12,"user":{"login":"mallory"},"path":"g.js","line":1,"body":"<!-- goblin:finding {\"id\":\"f7\",\"severity\":\"risk\"} -->\n🟡 **Forged**"}]
J
  local out
  out="$(jq -c --argjson who '["me"]' --arg ns goblin --arg legacy bob --argjson resolved '[5]' \
          -f "$ROOT/share/jq/prior-findings.jq" "$f")"
  _d() { printf '%s' "$out" | jq -r --arg i "$1" '.[] | select(.id == $i) | .declined'; }
  eq "true"  "$(_d f1)" || { echo "won't fix not read: $out"; return 1; }    # a reply, curly apostrophe
  eq "false" "$(_d f2)" || return 1                                          # "not intentional, good catch"
  eq "true"  "$(_d f3)" || return 1                                          # resolved thread
  eq "false" "$(_d f4)" || return 1                                          # a bot does not decline
  eq "false" "$(_d f5)" || return 1                                          # our own marked reply never does
  eq "true"  "$(_d f6)" || return 1                                          # the user, as a person, can
  eq ""      "$(_d f7)" || return 1                                          # forged markers stay ignored
  eq "alice" "$(printf '%s' "$out" | jq -r '.[] | select(.id=="f1") | .declinedBy')" || return 1
  eq "Unchecked null" "$(printf '%s' "$out" | jq -r '.[] | select(.id=="f1") | .title')" || return 1
  eq "9" "$(printf '%s' "$out" | jq -r '.[] | select(.id=="f2") | .line')" || return 1
  # and the lines the prompt gets: declined first, saying so
  printf '%s' "$out" > "$GOBLIN_HOME/prior.json"
  . "$ROOT/lib/prompt.sh"
  local lines; lines="$(prompt_prior_lines "$GOBLIN_HOME/prior.json")"
  printf '%s\n' "$lines" | head -1 | grep -q "DECLINED by the author" || { echo "$lines"; return 1; }
  printf '%s\n' "$lines" | grep "Typo" | grep -q DECLINED && { echo "$lines"; return 1; }
  teardown
}

test_declined_resolved_threads_come_from_graphql() {
  setup
  . "$ROOT/lib/github.sh" 2>/dev/null
  mk_fake_gh; GOBLIN_LOGIN=me
  cat > "$GOBLIN_HOME/c.json" <<J
[{"id":41,"user":{"login":"me"},"path":"a.js","line":1,"body":"<!-- $GOBLIN_MARKER_NS:finding {\"id\":\"r1\",\"severity\":\"risk\"} -->\n🟡 **One**"},
 {"id":42,"user":{"login":"me"},"path":"a.js","line":2,"body":"<!-- $GOBLIN_MARKER_NS:finding {\"id\":\"r2\",\"severity\":\"risk\"} -->\n🟡 **Two**"}]
J
  # two pages of threads; the resolved one is on page two
  echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":41}]}}]}}}}}' > "$GOBLIN_HOME/g1.json"
  echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true,"comments":{"nodes":[{"databaseId":42}]}}]}}}}}' > "$GOBLIN_HOME/g2.json"
  GH_FIXTURE="$GOBLIN_HOME/c.json"; GH_GRAPHQL="$GOBLIN_HOME/g1.json $GOBLIN_HOME/g2.json"; export GH_FIXTURE GH_GRAPHQL
  local out; out="$(gh_prior_findings a/b 1)"
  eq "false true" "$(printf '%s' "$out" | jq -r '[.[].declined | tostring] | join(" ")')" || { echo "$out"; return 1; }
  # GraphQL down: replies alone decide, nothing fails
  unset GH_GRAPHQL
  eq "false false" "$(gh_prior_findings a/b 1 | jq -r '[.[].declined | tostring] | join(" ")')" || return 1
  unset GH_FIXTURE
  teardown
}

# The whole path: a later push, a finding the author answered "won't fix" — the model
# raises it again, the Goblin drops it, and the prompt said why.
_declined_comments() { # <finding id> -> the PR's review comments
  jq -nc --arg id "$1" '[
    {id:901, user:{login:"me"}, path:"src/a.js", line:3,
     body:("<!-- goblin:finding {\"v\":1,\"id\":\"" + $id + "\",\"severity\":\"blocker\"} -->\n🔴 blocker **Unchecked input**\n\nx")},
    {id:902, user:{login:"alice"}, in_reply_to_id:901, body:"That is by design, wontfix."}]'
}

test_declined_findings_are_never_raised_again() {
  review_env
  "$G" review 2456 --repo acme/widgets >/dev/null 2>&1
  local id1 fid; id1="$(review_job_id)"
  fid="$(jq -r '.findings[] | select(.title=="Unchecked input") | .id' "$GOBLIN_HOME/jobs/$id1/preview/review.json")"
  [ -n "$fid" ] || { echo "no id to decline"; return 1; }
  rm -rf "$GOBLIN_HOME/jobs"
  _declined_comments "$fid" > "$GOBLIN_HOME/comments.json"
  export REVIEW_FAKE_COMMENTS="$GOBLIN_HOME/comments.json" REVIEW_FAKE_PRIOR="0ld0ld0" \
         CLAUDE_FAKE_PROMPT_OUT="$GOBLIN_HOME/prompt.txt"
  # incremental review OFF: only the declined one may be held back
  jq '.incrementalReview = false' "$GOBLIN_HOME/config.json" > "$GOBLIN_HOME/c.t" && mv "$GOBLIN_HOME/c.t" "$GOBLIN_HOME/config.json"
  "$G" review 2456 --repo acme/widgets >/dev/null 2>&1
  local id2; id2="$(review_job_id)"
  eq "ready" "$(jq -r .phase "$GOBLIN_HOME/jobs/$id2/job.json")" || return 1
  eq "Naming" "$(jq -r '[.findings[].title] | join(",")' "$GOBLIN_HOME/jobs/$id2/preview/review.json")" || { echo "the declined finding came back"; return 1; }
  grep -q "DECLINED by the author (@alice" "$GOBLIN_HOME/prompt.txt" || { echo "prompt does not say it was declined"; return 1; }
  grep -q "Unchecked input" "$GOBLIN_HOME/prompt.txt" || { echo "prompt does not name what was declined"; return 1; }
  eq "true" "$(jq -r '.[0].declined' "$GOBLIN_HOME/jobs/$id2/preview/prior.json")" || return 1
  review_env_done
}

test_declined_threads_get_no_fixed_reply() {
  setup
  . "$ROOT/lib/render.sh"; . "$ROOT/lib/post.sh"
  mk_fake_gh; GH_LOG="$GOBLIN_HOME/gh.log"; export GH_LOG
  echo '[{"id":"a","commentId":11,"declined":true},{"id":"b","commentId":12,"declined":false},{"id":"c","commentId":13},{"id":"d","commentId":14,"fixedReplied":true}]' > "$GOBLIN_HOME/prior.json"
  # the model said a and b are fixed; c is simply not repeated, which proves nothing
  echo '["a","b","d"]' > "$GOBLIN_HOME/cur.json"
  post_fixed_replies a/b 1 "$GOBLIN_HOME/prior.json" "$GOBLIN_HOME/cur.json" deadbeef
  grep -q "comments/11/replies" "$GH_LOG" && { echo "replied 'no longer flagged' on a declined thread"; return 1; }
  grep -q "comments/13/replies" "$GH_LOG" && { echo "replied 'no longer flagged' on a finding nobody said was fixed"; return 1; }
  grep -q "comments/14/replies" "$GH_LOG" && { echo "said 'no longer flagged' twice on one thread"; return 1; }
  grep -q "comments/12/replies" "$GH_LOG" || { echo "the real fixed reply is gone"; return 1; }
  # and it carries a marker, so nothing reads it as a person replying
  grep "comments/12/replies" "$GH_LOG" | grep -q "<!-- $GOBLIN_MARKER_NS:fixed " || { echo "fixed reply has no marker"; return 1; }
  teardown
}

# ------------------------------------------------------------- skip rules ---
test_skip_rules_decide_before_the_model() {
  setup
  cfg_backfill_defaults
  . "$ROOT/lib/diff.sh"; . "$ROOT/lib/skip.sh"
  mk_fake_gh
  cfg_repo_add a/b >/dev/null; cfg_repo_add c/d >/dev/null
  _files() { jq -nc '[$ARGS.positional[] | {filename:., status:"modified", additions:1, deletions:0, patch:"@@ -1 +1 @@\n-a\n+b"}]' --args "$@" > "$GOBLIN_HOME/files.json"; GH_FIXTURE="$GOBLIN_HOME/files.json"; export GH_FIXTURE; }
  local f="$GOBLIN_HOME/out.json" r
  # a dependency bot, by the spelling `gh pr list` uses and by the REST one
  _files src/a.js
  r="$(skip_check a/b 1 app/dependabot "$f")" || { echo "dependabot not skipped"; return 1; }
  eq "bot_author" "$(printf '%s' "$r" | jq -r .reason)" || return 1
  skip_check a/b 1 'renovate[bot]' "$f" >/dev/null || { echo "renovate not skipped"; return 1; }
  # a person is not
  skip_check a/b 1 alice "$f" >/dev/null && { echo "a real PR was skipped"; return 1; }
  # only lockfiles: skipped, and it says why
  _files web/yarn.lock package-lock.json go.sum
  r="$(skip_check a/b 1 alice "$f")" || { echo "lockfile-only PR not skipped"; return 1; }
  eq "skip_paths" "$(printf '%s' "$r" | jq -r .reason)" || return 1
  printf '%s' "$r" | jq -r .detail | grep -q "3 files" || { echo "$r"; return 1; }
  # a lockfile plus real code is a real PR
  _files yarn.lock src/a.js
  skip_check a/b 1 alice "$f" >/dev/null && { echo "skipped a PR with real code"; return 1; }
  # docs only: off by default, on when asked
  _files README.md docs/guide.md
  skip_check a/b 1 alice "$f" >/dev/null && { echo "docs-only skipped while off"; return 1; }
  cfg_set '.skip.docsOnly = true'
  eq "docs_only" "$(skip_check a/b 1 alice "$f" | jq -r .reason)" || return 1
  # per repo: c/d opts its bot PRs back in and narrows the paths; a/b is untouched
  cfg_set '.repos |= map(if .slug == "c/d" then .skip = {bots:false, paths:["*.lock"]} else . end)'
  _files src/a.js
  skip_check c/d 1 'dependabot[bot]' "$f" >/dev/null && { echo "repo opt-in ignored"; return 1; }
  skip_check a/b 1 'dependabot[bot]' "$f" >/dev/null || { echo "an override leaked to another repo"; return 1; }
  _files package-lock.json
  skip_check c/d 1 alice "$f" >/dev/null && { echo "repo paths did not replace the global list"; return 1; }
  # the global switch
  cfg_set '.skip.bots = false'
  _files src/a.js
  skip_check a/b 1 'dependabot[bot]' "$f" >/dev/null && { echo "bots skipped with the rule off"; return 1; }
  unset GH_FIXTURE
  teardown
}

test_skip_manual_review_says_why_unless_forced() {
  review_env
  export REVIEW_FAKE_AUTHOR='dependabot[bot]'
  "$G" review 2456 --repo acme/widgets >/dev/null 2>&1
  local id; id="$(review_job_id)"
  eq "skipped"    "$(jq -r .phase "$GOBLIN_HOME/jobs/$id/job.json")"  || return 1
  eq "bot_author" "$(jq -r .reason "$GOBLIN_HOME/jobs/$id/job.json")" || return 1
  jq -r .reasonDetail "$GOBLIN_HOME/jobs/$id/job.json" | grep -q "dependency bot" || return 1
  [ -e "$GOBLIN_HOME/events.jsonl" ] && grep -q '"posted"\|"previewed"' "$GOBLIN_HOME/events.jsonl" && { echo "a model ran"; return 1; }
  local out; out="$("$G" job "$id" 2>/dev/null)"
  printf '%s' "$out" | grep -q "skipped: opened by dependabot\[bot\]" || { echo "$out"; return 1; }
  # forced: reviewed after all
  rm -rf "$GOBLIN_HOME/jobs"
  "$G" review 2456 --repo acme/widgets --force >/dev/null 2>&1
  eq "ready" "$(jq -r .phase "$GOBLIN_HOME/jobs/$(review_job_id)/job.json")" || return 1
  # lockfile-only, by a person
  rm -rf "$GOBLIN_HOME/jobs"; unset REVIEW_FAKE_AUTHOR
  echo '[{"filename":"yarn.lock","status":"modified","additions":3,"deletions":3,"patch":"@@ -1 +1 @@\n-a\n+b"}]' > "$GOBLIN_HOME/files.json"
  export REVIEW_FAKE_FILES="$GOBLIN_HOME/files.json"
  "$G" review 2456 --repo acme/widgets >/dev/null 2>&1
  eq "skip_paths" "$(jq -r .reason "$GOBLIN_HOME/jobs/$(review_job_id)/job.json")" || return 1
  review_env_done
}

test_skip_scheduled_path_records_the_reason() {
  review_env
  export REVIEW_FAKE_AUTHOR='renovate[bot]'
  "$G" run --pr 2456 --repo acme/widgets >/dev/null 2>&1
  grep -q '"status":"skipped"' "$GOBLIN_HOME/events.jsonl" || { echo "no skipped event"; cat "$GOBLIN_HOME/events.jsonl" 2>/dev/null; return 1; }
  jq -r 'select(.status=="skipped") | .reason' "$GOBLIN_HOME/events.jsonl" | grep -q "dependency bot" || return 1
  grep -qxF "2456:aaaaaaa1111111" "$GOBLIN_HOME/ledger" || { echo "a skipped PR will be re-checked every cycle"; return 1; }
  [ -s "$REVIEW_FAKE_POSTED" ] && { echo "a skipped PR was posted to"; return 1; }
  grep -q "pulls/2456/files" "$REVIEW_FAKE_LOG" && { echo "a bot PR cost a files call"; return 1; }
  # the panel's two switches reach the config, and the app sees them
  "$G" panel set flag skip-bots off >/dev/null 2>&1 || return 1
  "$G" panel set flag skip-docs-only on >/dev/null 2>&1 || return 1
  eq "false" "$(jq -r '.skip.bots' "$GOBLIN_HOME/config.json")" || return 1
  eq "true"  "$(jq -r '.skip.docsOnly' "$GOBLIN_HOME/config.json")" || return 1
  eq "false true" "$(jq -r '"\(.settings.skip.bots) \(.settings.skip.docsOnly)"' "$GOBLIN_HOME/uistate.json")" || return 1
  review_env_done
}

# --------------------------------------------------- provider per repo -----
test_repo_provider_cli_is_validated() {
  review_env
  "$G" repo provider acme/widgets codex gpt-5 >/dev/null 2>&1 || return 1
  eq "codex gpt-5" "$(jq -r '.repos[] | select(.slug=="acme/widgets") | "\(.provider) \(.model)"' "$GOBLIN_HOME/config.json")" || return 1
  "$G" repos list 2>/dev/null | grep -q "acme/widgets  (codex/gpt-5)" || return 1
  "$G" repo provider acme/widgets default >/dev/null 2>&1 || return 1
  eq "null null" "$(jq -r '.repos[] | select(.slug=="acme/widgets") | "\(.provider) \(.model)"' "$GOBLIN_HOME/config.json")" || return 1
  local before; before="$(cat "$GOBLIN_HOME/config.json")"
  "$G" repo provider acme/widgets gpt5 >/dev/null 2>&1;            eq 2 "$?" || return 1
  "$G" repo provider acme/widgets claude 'x;y' >/dev/null 2>&1;    eq 2 "$?" || return 1
  "$G" repo provider nobody/watched claude >/dev/null 2>&1;        eq 1 "$?" || return 1
  "$G" panel set repo-provider acme/widgets codex '--x' >/dev/null 2>&1 && return 1
  "$G" panel set repo-provider '../x' codex '' >/dev/null 2>&1 && return 1
  eq "$before" "$(cat "$GOBLIN_HOME/config.json")" || { echo "a refused value changed the config"; return 1; }
  # the app sees it
  "$G" panel set repo-provider acme/widgets claude opus >/dev/null 2>&1 || return 1
  eq "claude opus" "$(jq -r '.repos[] | select(.slug=="acme/widgets") | "\(.provider) \(.model)"' "$GOBLIN_HOME/uistate.json")" || return 1
  review_env_done
}

test_repo_provider_is_used_unless_the_review_names_one() {
  review_env
  "$G" repo provider acme/widgets claude opus-for-widgets >/dev/null 2>&1 || return 1
  "$G" review 2456 --repo acme/widgets >/dev/null 2>&1
  eq "opus-for-widgets" "$(jq -r .model "$GOBLIN_HOME/jobs/$(review_job_id)/preview/meta.json")" || return 1
  rm -rf "$GOBLIN_HOME/jobs"
  "$G" review 2456 --repo acme/widgets --model haiku-asked >/dev/null 2>&1
  eq "haiku-asked" "$(jq -r .model "$GOBLIN_HOME/jobs/$(review_job_id)/preview/meta.json")" || return 1
  rm -rf "$GOBLIN_HOME/jobs"
  "$G" review 2456 --repo acme/widgets --provider claude >/dev/null 2>&1
  eq "opus-for-widgets" "$(jq -r .model "$GOBLIN_HOME/jobs/$(review_job_id)/preview/meta.json")" || return 1
  # never written into the global settings
  jq -e '.providers.claude.model != "opus-for-widgets"' "$GOBLIN_HOME/config.json" >/dev/null || { echo "repo model leaked into the global one"; return 1; }
  # the scheduled path uses it too
  export CLAUDE_FAKE_ARGS_OUT="$GOBLIN_HOME/args.txt"
  "$G" run --pr 2456 --repo acme/widgets --force >/dev/null 2>&1
  grep -qx "opus-for-widgets" "$GOBLIN_HOME/args.txt" || { echo "scheduled run ignored the repo model"; return 1; }
  review_env_done
}

test_repo_provider_falls_back_when_unusable() {
  setup
  . "$ROOT/lib/providers.sh"; providers_load
  . "$ROOT/lib/diff.sh" 2>/dev/null; . "$ROOT/lib/engine.sh" 2>/dev/null
  cfg_repo_add a/b >/dev/null
  cfg_set '.repos |= map(.provider = "cursor" | .model = "m-1")'
  provider_cursor_probe() { echo '{"available":false,"authed":false}'; }
  engine_repo_provider a/b claude >/dev/null
  eq "claude|" "$ENGINE_REPO_PROVIDER|$ENGINE_REPO_MODEL" || return 1      # its model goes with it
  provider_cursor_probe() { echo '{"available":true,"authed":true}'; }
  engine_repo_provider a/b claude >/dev/null
  eq "cursor|m-1" "$ENGINE_REPO_PROVIDER|$ENGINE_REPO_MODEL" || return 1
  cfg_set '.repos |= map(.provider = "evil;rm" | .model = "m")'
  engine_repo_provider a/b claude >/dev/null
  eq "claude|" "$ENGINE_REPO_PROVIDER|$ENGINE_REPO_MODEL" || return 1
  teardown
}

# ----------------------------------------------------------------- codex ---
# A fake codex: `exec` records its argv and cwd and answers; `sandbox` behaves as
# FAKE_CODEX_SANDBOX says — confine (reads only inside the granted dir), leaky (reads
# anything: a codex that ignores the profile) or missing (no such subcommand).
_fake_codex() {
  local bin="$GOBLIN_HOME/bin"; mkdir -p "$bin"
  cat > "$bin/codex" <<'S'
#!/bin/bash
case "$1" in
  --version) echo "codex-cli 9.9.9-fake"; exit 0 ;;
  sandbox)
    case "${FAKE_CODEX_SANDBOX:-confine}" in
      missing) echo "error: unrecognized subcommand 'sandbox'" >&2; exit 2 ;;
    esac
    prof=""; prev=""; target=""
    for a in "$@"; do
      case "$prev" in -c) case "$a" in permissions.*) prof="$a" ;; esac ;; esac
      prev="$a"; target="$a"
    done
    if [ "${FAKE_CODEX_SANDBOX}" = leaky ]; then cat "$target"; exit $?; fi
    grant="$(printf '%s' "$prof" | grep -oE '"/[^"]+"="read"' | grep -v '"/tmp"\|"/private/tmp"' | head -1 | sed 's/"="read"//; s/^"//')"
    case "$target" in "$grant"/*) cat "$target"; exit $? ;; esac
    echo "cat: $target: Operation not permitted" >&2; exit 1 ;;
  exec)
    printf '%s\n' "$@" > "$GOBLIN_ARGS_OUT"; pwd > "$GOBLIN_ARGS_OUT.cwd"
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "--output-last-message" ] && out="$a"; prev="$a"; done
    cat >/dev/null
    printf '{"summary":"s","findings":[]}' > "$out"
    echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
    exit 0 ;;
esac
exit 0
S
  chmod +x "$bin/codex"
  cfg_set --arg b "$bin/codex" '.providers.codex.bin = $b'
  export GOBLIN_ARGS_OUT="$GOBLIN_HOME/args"
}

test_codex_reads_are_confined_to_the_checkout() {
  setup
  . "$ROOT/lib/findings.sh" 2>/dev/null; . "$ROOT/lib/providers/codex.sh"
  _fake_codex
  mkdir -p "$GOBLIN_HOME/co/.git" "$GOBLIN_HOME/raw"; echo hi > "$GOBLIN_HOME/prompt"
  local schema="$ROOT/share/schema/findings.schema.json"
  export FAKE_CODEX_SANDBOX=confine
  provider_codex_review "$GOBLIN_HOME/prompt" "$GOBLIN_HOME/co" "$schema" "$GOBLIN_HOME/out.json" "$GOBLIN_HOME/raw" >/dev/null 2>&1 \
    || { echo "review failed"; return 1; }
  local args; args="$(cat "$GOBLIN_ARGS_OUT")"
  eq "true" "${GOBLIN_P_CONFINED:-}" || return 1
  printf '%s\n' "$args" | grep -qx 'default_permissions="goblin"' || { echo "no permission profile: $args"; return 1; }
  printf '%s\n' "$args" | grep -F 'permissions.goblin.filesystem=' | grep -qF "\"$GOBLIN_HOME/co\"=\"read\"" \
    || { echo "checkout not the readable root"; return 1; }
  printf '%s\n' "$args" | grep -F 'permissions.goblin.filesystem=' | grep -qF '"/tmp"="none"' || { echo "/tmp not denied"; return 1; }
  printf '%s\n' "$args" | grep -F 'permissions.goblin.filesystem=' | grep -q '"write"' && { echo "a write grant"; return 1; }
  printf '%s\n' "$args" | grep -qx -- '--sandbox' && { echo "--sandbox would override the profile"; return 1; }
  printf '%s\n' "$args" | grep -qx 'project_doc_max_bytes=0' || { echo "the PR's AGENTS.md would be loaded"; return 1; }
  [ "$(cat "$GOBLIN_ARGS_OUT.cwd")" != "$GOBLIN_HOME/co" ] || { echo "ran inside the PR checkout"; return 1; }
  printf '%s\n' "$args" | grep -A1 -x -- '--cd' | tail -1 | grep -q "/raw/cwd$" || { echo "--cd is not the empty dir"; return 1; }
  # no checkout: nothing of the user's is readable at all
  rm -rf "$GOBLIN_HOME/co/.git"
  provider_codex_review "$GOBLIN_HOME/prompt" "$GOBLIN_HOME/co" "$schema" "$GOBLIN_HOME/out.json" "$GOBLIN_HOME/raw" >/dev/null 2>&1
  grep -F 'permissions.goblin.filesystem=' "$GOBLIN_ARGS_OUT" | grep -qF "$GOBLIN_HOME" && { echo "a grant without a checkout"; return 1; }
  # a codex that ignores the profile, or has no sandbox command: fall back, and say so
  local mode
  for mode in leaky missing; do
    mkdir -p "$GOBLIN_HOME/co/.git"; export FAKE_CODEX_SANDBOX="$mode"
    # not $(…): GOBLIN_P_CONFINED must be set in THIS shell
    provider_codex_review "$GOBLIN_HOME/prompt" "$GOBLIN_HOME/co" "$schema" "$GOBLIN_HOME/out.json" "$GOBLIN_HOME/raw" > "$GOBLIN_HOME/log.txt" 2>&1
    eq "false" "${GOBLIN_P_CONFINED:-}" || { echo "$mode: claimed confinement"; return 1; }
    grep -qx -- 'read-only' "$GOBLIN_ARGS_OUT" || { echo "$mode: no read-only sandbox"; return 1; }
    grep -q 'default_permissions' "$GOBLIN_ARGS_OUT" && { echo "$mode: both sandbox and profile"; return 1; }
    grep -q "NOT confined" "$GOBLIN_HOME/log.txt" || { echo "$mode: fell back silently"; return 1; }
  done
  unset FAKE_CODEX_SANDBOX
  teardown
}

test_codex_profile_quotes_paths() {
  setup
  . "$ROOT/lib/providers/codex.sh"
  local p; p="$(provider_codex_profile '/a "b"/c\d')"
  printf '%s' "$p" | grep -qF '"/a \"b\"/c\\d"="read"' || { echo "$p"; return 1; }
  # a control character is never written into the profile
  p="$(provider_codex_profile "$(printf '/x\ny')")"
  printf '%s' "$p" | grep -q '/x' && { echo "$p"; return 1; }
  teardown
}

# Against the REAL codex sandbox when one is installed (no model, no network, no
# account: `codex sandbox` only runs /bin/cat under Seatbelt). Passes trivially elsewhere.
test_codex_real_sandbox_confines_when_installed() {
  setup
  . "$ROOT/lib/providers/codex.sh"
  local bin; bin="$(command -v codex 2>/dev/null || true)"
  if [ -z "$bin" ] || ! "$bin" sandbox --help >/dev/null 2>&1; then teardown; return 0; fi
  local ch; ch="$(mktemp -d)"
  CODEX_HOME="$ch" provider_codex_can_confine "$bin" "$GOBLIN_HOME" \
    || { echo "this codex ($("$bin" --version 2>/dev/null)) cannot confine reads — reviews fall back to read-only"; rm -rf "$ch"; return 1; }
  rm -rf "$ch"
  teardown
}
