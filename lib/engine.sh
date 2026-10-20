#!/usr/bin/env bash
# engine.sh — poll → gate → claim → review → post → release.
#
# Gate order is cheapest-first on purpose: most cycles do no network work at all.
#   draft → local ledger → fleet assignment → GitHub idempotency → atomic claim

# shellcheck source=providers.sh
. "$LIB_DIR/providers.sh"
. "$LIB_DIR/findings.sh"
. "$LIB_DIR/refute.sh"
. "$LIB_DIR/github.sh"
. "$LIB_DIR/render.sh"
. "$LIB_DIR/post.sh"
. "$LIB_DIR/claim.sh"
. "$LIB_DIR/prompt.sh"
. "$LIB_DIR/diff.sh"
. "$LIB_DIR/update.sh"
. "$LIB_DIR/attempts.sh"
. "$LIB_DIR/inbox.sh"
. "$LIB_DIR/jobs.sh"

ONLY_PR=""; ONLY_REPO=""; DRY_RUN=false; FORCE=false; SCHEDULED=false
# PREVIEW: run the whole review but stop before posting — the result is saved for a
# person to read first (see engine_save_preview). Only manual jobs set it.
PREVIEW=false
GOBLIN_LAST_REVIEW_URL=""
REVIEWS_THIS_RUN=0

cmd_run() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)        ONLY_PR="$2"; shift $(( $# > 1 ? 2 : 1 )) ;;
      --repo)      ONLY_REPO="$2"; shift $(( $# > 1 ? 2 : 1 )) ;;
      --plan|--dry-run) DRY_RUN=true; shift ;;
      --force)     FORCE=true; shift ;;
      --scheduled) SCHEDULED=true; shift ;;
      *) echo "goblin run: unknown option $1" >&2; return 2 ;;
    esac
  done

  cfg_ensure; cfg_backfill_defaults; goblin_ensure_dirs
  # Only the scheduled path writes to the log file; interactive runs print.
  [ "$SCHEDULED" = true ] && log_open

  if ! lock_acquire; then
    log "another run is active, exiting"
    # A scheduled cycle can safely skip; a person who asked for one PR cannot be left
    # thinking it happened. `goblin review` has no such lock and runs alongside.
    if [ -n "$ONLY_PR" ]; then
      echo "goblin: a scheduled run is in progress. Use  goblin review $ONLY_PR  (runs alongside it) or try again in a minute." >&2
      return 1
    fi
    return 0
  fi
  # EXIT cleans up; a signal must END the run (not just clean up and carry on
  # reviewing and posting), and then the EXIT trap does the cleanup exactly once.
  trap 'claim_release; claim_release_comment; lock_release' EXIT
  trap 'exit 130' INT TERM

  log "=== run start ${ONLY_PR:+(pr #$ONLY_PR) }${DRY_RUN:+}$([ "$DRY_RUN" = true ] && echo '(dry run)')"

  engine_gates || { lock_release; return 0; }
  engine_auth  || { lock_release; return 1; }

  local provider
  # Load the adapters in THIS shell. providers_pick also loads them, but it runs
  # inside a command substitution — a subshell — so its sourcing is discarded and
  # provider_<name>_review would not exist by the time the engine calls it.
  providers_load
  provider="$(providers_pick)" || {
    log "no usable provider (run: goblin provider list)"
    status_set '{"state":"error","activity":"no usable AI provider"}'
    return 1
  }
  log "provider: $provider"

  local slug repos
  repos="$(cfg_repos_enabled)"
  [ -n "$ONLY_REPO" ] && repos="$ONLY_REPO"
  # A bare PR number means ONE pull request. Looping it over every watched repo would
  # review whatever happens to share that number in each of them.
  if [ -n "$ONLY_PR" ] && [ -z "$ONLY_REPO" ]; then
    . "$LIB_DIR/review.sh"
    if ! ref_resolve_or_fail "$ONLY_PR" "" false; then
      lock_release; return 2
    fi
    repos="$REF_SLUG"; ONLY_PR="$REF_NUM"
  fi
  if [ -z "$repos" ]; then
    log "no repos configured — run: goblin repos add owner/name"
    return 0
  fi

  for slug in $repos; do
    engine_repo "$slug" "$provider"
  done

  # After the reviews, never before: a version check is the least important thing
  # this run does and must not delay or risk the work. Throttled to once a day
  # inside update_check, and it runs before the status write below so the panel
  # picks the flag up on this run rather than the next one.
  update_check
  local newer; newer="$(update_available)" && \
    log "update available: v$GOBLIN_VERSION → v$newer ($(update_instructions))"

  local fin; fin="$(now_epoch)"
  status_set "$(jq -nc --argjson f "$fin" \
    --argjson n "$((fin + $(cfg_get '.intervalSeconds' 900)))" \
    '{state:"idle",pausedReason:"",activity:"",lastRunFinished:$f,nextRunEstimate:$n}')"
  log "=== run done ($REVIEWS_THIS_RUN reviewed) ==="
}

# --- gates ----------------------------------------------------------------
engine_gates() {
  # A targeted run is a deliberate manual act; it bypasses the scheduling gates.
  [ -n "$ONLY_PR" ] && return 0
  [ "$FORCE" = true ] && return 0

  if [ "$(cfg_get '.enabled' true)" != "true" ]; then
    log "disabled via config"; status_set '{"state":"paused","pausedReason":"manual","activity":""}'; return 1
  fi
  local snooze now; snooze="$(cfg_get '.snoozeUntil' 0)"; now="$(now_epoch)"
  if [ "${snooze:-0}" -gt 0 ] 2>/dev/null; then
    if [ "$now" -lt "$snooze" ]; then
      log "snoozed until $snooze"
      status_set "$(jq -nc --argjson u "$snooze" '{state:"snoozed",pausedReason:"snoozed",snoozeUntil:$u}')"
      return 1
    fi
    log "snooze expired"; cfg_set '.snoozeUntil=0'
  fi
  engine_budget_ok || return 1

  status_set "$(jq -nc --argjson t "$now" '{state:"idle",pausedReason:"",activity:"",lastRunStarted:$t}')"
  return 0
}

# Checked before EVERY review, not just at run start — a backlog run used to
# blow past the cap by 2x before the next cycle noticed.
engine_budget_ok() {
  # A review somebody asked for by number is not part of the unattended budget: the
  # caps exist to stop a backlog running away, and this is one deliberate PR.
  [ -n "$ONLY_PR" ] && return 0
  local cap spent max_run max_day done_today
  cap="$(cfg_get '.budgetCapUsd' 0)"
  max_run="$(cfg_get '.maxReviewsPerRun' 5)"
  max_day="$(cfg_get '.maxReviewsPerDay' 0)"

  if [ "${max_run:-0}" -gt 0 ] && [ "$REVIEWS_THIS_RUN" -ge "$max_run" ]; then
    log "hit maxReviewsPerRun ($max_run) — stopping this cycle"
    return 1
  fi

  # A count cap as well as a dollar cap, because the dollar cap cannot protect a
  # subscription provider: `cost not reported` means today_spend() stays at 0
  # forever and budgetCapUsd never fires. On a repo with a large backlog that is
  # an unbounded number of reviews against a subscription with its own hidden
  # quota — and hitting a provider's quota is the failure that takes the Goblin
  # down for everyone on the team, not just for the PR that tripped it.
  if [ "${max_day:-0}" -gt 0 ] 2>/dev/null; then
    done_today="$(today_review_count)"
    if [ "${done_today:-0}" -ge "$max_day" ] 2>/dev/null; then
      log "hit maxReviewsPerDay ($done_today/$max_day) — resumes tomorrow"
      status_set '{"state":"paused","pausedReason":"quota","activity":""}'
      return 1
    fi
  fi
  spent="$(today_spend)"
  if [ "$(jq -n --argjson c "${cap:-0}" --argjson s "${spent:-0}" '($c>0) and ($s>=$c)' 2>/dev/null)" = "true" ]; then
    log "daily budget reached (\$$spent >= \$$cap)"
    local marker="$GOBLIN_HOME/.budget-notified" today; today="$(date +%Y-%m-%d)"
    if [ "$(cat "$marker" 2>/dev/null)" != "$today" ]; then
      notify budget "$GOBLIN_NAME paused 💸" "daily budget \$$cap reached (\$$spent) — resumes tomorrow"
      echo "$today" > "$marker"
    fi
    status_set '{"state":"paused","pausedReason":"budget","activity":""}'
    return 1
  fi
  return 0
}

engine_auth() {
  command -v gh  >/dev/null 2>&1 || { log "gh not found"; return 1; }
  command -v git >/dev/null 2>&1 || { log "git not found"; return 1; }
  GOBLIN_LOGIN="$(goblin_login)"
  gh_pin_token "$GOBLIN_LOGIN" || { log "could not obtain a gh token for '$GOBLIN_LOGIN'"; return 1; }
  if ! gh_assert_identity "$GOBLIN_LOGIN"; then
    log "token identity mismatch: token is '$(gh api user --jq .login 2>/dev/null)', expected '$GOBLIN_LOGIN' — abort"
    notify failed "$GOBLIN_NAME ⚠️" "github token is not $GOBLIN_LOGIN"
    return 1
  fi
  # launchd can't reach the macOS keychain, so git gets its credentials from the
  # token via URL rewrite. Env vars mean every child git process inherits it.
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="url.https://x-access-token:${GH_TOKEN}@github.com/.insteadOf"
  export GIT_CONFIG_VALUE_0="https://github.com/"
  return 0
}

# --- per repo -------------------------------------------------------------
engine_repo() {
  local slug="$1" provider="$2" prs="$RUNTMP/prs-$$.json"

  if [ -n "$ONLY_PR" ]; then
    local meta="$RUNTMP/meta-$$.json"
    gh_pr_meta "$slug" "$ONLY_PR" "$meta" || { log "$slug#$ONLY_PR: not found"; return 1; }
    jq -c '[{number, head, draft:false, title, url, base, author,
             updatedAt:0, requested:[]}]' "$meta" > "$prs" 2>/dev/null
  else
    gh_prs "$slug" "$prs" || { log "$slug: could not list PRs (no access?)"; return 1; }
  fi

  # Oldest PR first. `gh pr list` returns newest-first, which is exactly the
  # wrong order under a per-run cap: the PR closest to being merged is the one
  # that gets reviewed last, or not at all. #1441 was the oldest of the three
  # queued at 12:34 and was served third, 6 minutes after it merged.
  if [ -z "$ONLY_PR" ]; then
    jq 'sort_by(.createdAt // 0)' "$prs" > "$prs.sorted" 2>/dev/null \
      && [ -s "$prs.sorted" ] && mv "$prs.sorted" "$prs"
  fi

  local n; n="$(jq 'length' "$prs" 2>/dev/null || echo 0)"
  log "$slug: $n open PR(s)"

  local i=0 entry
  while [ "$i" -lt "${n:-0}" ]; do
    entry="$(jq -c --argjson i "$i" '.[$i]' "$prs")"
    i=$((i + 1))
    engine_pr "$slug" "$entry" "$provider" || true
  done
  rm -f "$prs" "$prs.sorted" 2>/dev/null
}

# --- failure backoff -------------------------------------------------------
# Moved to lib/attempts.sh (sourced above) so inbox.sh and state.sh can read the
# same file without sourcing this one. Behaviour is unchanged.

# --- per PR ---------------------------------------------------------------
engine_pr() {
  local slug="$1" entry="$2" provider="$3"
  local pr head title url base draft
  pr="$(printf '%s' "$entry"    | jq -r '.number')"
  head="$(printf '%s' "$entry"  | jq -r '.head')"
  title="$(printf '%s' "$entry" | jq -r '.title')"
  url="$(printf '%s' "$entry"   | jq -r '.url')"
  base="$(printf '%s' "$entry"  | jq -r '.base')"
  draft="$(printf '%s' "$entry" | jq -r '.draft')"

  [ "$draft" = "true" ] && { log "  #$pr: draft, skipping"; return 0; }

  local key="${pr}:${head}"
  if [ "$FORCE" != true ] && [ -z "$ONLY_PR" ] && ledger_has "$key"; then return 0; fi

  if [ "$FORCE" != true ] && attempt_blocked "$key"; then
    log "  #$pr: backing off after repeated failures, skipping"
    return 0
  fi

  # --- gate: is this PR mine to review? (free) ---
  if [ -z "$ONLY_PR" ] && [ "$(cfg_get '.fleetAssignment' true)" = "true" ]; then
    local eligible assignee
    eligible="$(claim_eligible "$entry")"
    if [ -z "$eligible" ]; then
      return 0   # nobody in the fleet was asked — not ours
    fi
    assignee="$(claim_assignee "$pr" "$head" "$eligible")"
    if [ "$assignee" != "$GOBLIN_LOGIN" ]; then
      # Unless the assignee looks offline: without this, reviews vanish whenever
      # someone's laptop is asleep.
      local updated grace now
      updated="$(printf '%s' "$entry" | jq -r '.updatedAt // 0')"
      grace="$(cfg_get '.takeoverGraceSecs' 2700)"; now="$(now_epoch)"
      if [ "$(( now - ${updated:-0} ))" -lt "${grace:-2700}" ]; then
        log "  #$pr: assigned to $assignee, skipping"
        return 0
      fi
      log "  #$pr: assigned to $assignee but stale — attempting takeover"
    fi
  fi

  # --- gate: has this exact commit already been reviewed? (1 call) ---
  local prior last_sha=""
  prior="$(gh_prior_review "$slug" "$pr")"
  if [ -n "$prior" ]; then
    last_sha="$(printf '%s' "$prior" | jq -r '.m.headSha // ""')"
    if [ "$last_sha" = "$head" ] && [ "$FORCE" != true ]; then
      log "  #$pr: already reviewed at $(trunc "$head" 7)"
      ledger_add "$key"
      return 0
    fi
  fi

  # --- gate: has a person already reviewed it? ---
  # Free: reuses the reviews page fetched for the gate above. The Goblin exists to
  # look at PRs nobody has looked at; once a colleague has left a real review,
  # adding an automated one on top is noise on a thread that already has a human
  # owner. Its own reviews are excluded by marker inside gh_human_reviewers — they
  # are posted under a human token and are otherwise indistinguishable, and without
  # that exclusion the Goblin sees itself and never reviews the repo again.
  if [ "$(cfg_get '.skipIfHumanReviewed' true)" = "true" ] && [ "$FORCE" != true ] \
     && [ -z "$ONLY_PR" ]; then
    local rj humans; rj="$RUNTMP/reviews-$pr-$$.json"
    if gh_reviews_fetch "$slug" "$pr" "$rj"; then
      humans="$(gh_human_reviewers "$rj" | paste -sd, - 2>/dev/null)"
      if [ -n "$humans" ]; then
        log "  #$pr: already reviewed by $humans, skipping"
        ledger_add "$key"
        rm -f "$rj" 2>/dev/null
        return 0
      fi
    fi
    rm -f "$rj" 2>/dev/null
  fi

  engine_budget_ok || return 1

  # --- gate: is it still open? (1 call, saves a whole model run) ---
  # The PR list is a snapshot from the top of the run; anything in it may have
  # merged since. Reviewing a merged PR costs a model call and posts advice
  # nobody will read.
  if [ "$DRY_RUN" != true ] && ! gh_pr_is_open "$slug" "$pr"; then
    log "  #$pr: already merged or closed, skipping"
    ledger_add "$key"
    return 0
  fi

  # --- gate: atomic claim (authoritative) ---
  if [ "$DRY_RUN" != true ] && [ -z "$ONLY_PR" ]; then
    if [ "$(cfg_get '.refsForbidden' false)" = "true" ]; then
      claim_try_comment "$slug" "$pr" "$head" || { log "  #$pr: another bot claimed it"; return 0; }
    else
      claim_try "$slug" "$pr" "$head"
      case $? in
        0) : ;;
        2) claim_try_comment "$slug" "$pr" "$head" || { log "  #$pr: claimed elsewhere"; return 0; } ;;
        3) log "  #$pr: could not take the claim just now (network or rate limit) — next cycle"; return 0 ;;
        *) log "  #$pr: claimed by another bot"; ledger_add "$key"; return 0 ;;
      esac
    fi
    claim_sweep "$slug" "$pr" "$head"
  fi

  engine_review_pr "$slug" "$pr" "$head" "$title" "$url" "$base" "$provider" "$last_sha"
  local rc=$?
  claim_release; claim_release_comment
  return $rc
}

# --- the actual review ----------------------------------------------------
# Serialised per repo: the scratch clone is shared and is reset --hard before every
# checkout, which would pull the files out from under a model that is reading them.
engine_review_pr() {
  local slug="$1" rc
  if ! repo_lock_acquire "$slug"; then
    log "  #$2: could not get the repo lock for $slug"
    return 1
  fi
  engine_review_pr_locked "$@"; rc=$?
  repo_lock_release
  return $rc
}

engine_review_pr_locked() {
  local slug="$1" pr="$2" head="$3" title="$4" url="$5" base="$6" provider="$7" last_sha="$8"
  local work="$RUNTMP/pr-$pr-$$"; rm -rf "$work"; mkdir -p "$work/raw"

  log "  #$pr: reviewing ($title)"
  status_set "$(jq -nc --arg a "reviewing #$pr — $title" '{state:"reviewing",activity:$a}')"
  # A manual job has its own progress UI; a banner for something you just asked for
  # is noise.
  [ -z "$GOBLIN_JOB_ID" ] && notify started "$GOBLIN_NAME is reviewing" "#$pr — $title"
  [ "$DRY_RUN" != true ] && [ "$PREVIEW" != true ] && gh_status "$slug" "$head" pending "reviewing with $provider"

  # 1. the diff, from GitHub (source of truth for what is commentable)
  job_phase fetching
  if ! diff_fetch_files "$slug" "$pr" "$work/files.json"; then
    log "  #$pr: no files returned"; rm -rf "$work"
    job_phase failed '{"error":"no_files","errorDetail":"GitHub returned no changed files for this pull request."}'
    return 1
  fi
  diff_addressable "$work/files.json" "$work/addr.json"
  diff_annotated  "$work/files.json" "$work/diff.txt" "$(cfg_get '.maxDiffBytes' 400000)"

  # 2. a checkout, so the model can read surrounding code
  job_phase reading
  local repo_dir; repo_dir="$(goblin_repo_dir "$slug")"
  # `checkout` stays empty unless THIS pull request is really checked out: a stale
  # clone left over from another PR must never be read or reviewed as if it were this one.
  local checkout=""
  if engine_checkout "$slug" "$pr" "$repo_dir"; then checkout="$repo_dir"
  else log "  #$pr: no local checkout (reviewing from diff only)"; fi

  # 3. context: PR meta, ticket, findings already posted
  gh_pr_meta "$slug" "$pr" "$work/pr.json" \
    || jq -nc --argjson n "$pr" --arg t "$title" --arg b "$base" '{number:$n,title:$t,body:"",base:$b,author:""}' > "$work/pr.json"
  gh_ticket_context "$slug" "$pr" "$work/pr.json" "$work/ticket.txt" >/dev/null
  : > "$work/prior.txt"
  local prior_json="$work/prior.json"; echo '[]' > "$prior_json"
  if [ -n "$last_sha" ] && [ "$(cfg_get '.incrementalReview' true)" = "true" ]; then
    gh_prior_findings "$slug" "$pr" > "$prior_json" 2>/dev/null || echo '[]' > "$prior_json"
    jq -r 'def one: tostring | gsub("[\\n\\r]+";" ") | .[0:200]; .[] | "- \(.severity // "?" | one): \(.path // "?" | one):\(.line // "?" | one)"' "$prior_json" > "$work/prior.txt" 2>/dev/null
    log "  #$pr: incremental (last reviewed $(trunc "$last_sha" 7), $(jq 'length' "$prior_json") prior finding(s))"
  fi

  : > "$work/others.txt"
  gh_other_comments "$slug" "$pr" > "$work/others.txt" 2>/dev/null || : > "$work/others.txt"

  # 4. assemble the prompt from THIS repo's own review rules — as they are on the base
  # branch, not as the pull request left them (see prompt_rules_view).
  local rules_dir="$work/rules"
  prompt_rules_view "$repo_dir" "$base" "$slug" "$rules_dir" \
    || log "  #$pr: no base branch to read the review rules from (using the general reviewer)"
  prompt_build "$rules_dir" "$slug" "$work/pr.json" "$work/diff.txt" \
               "$work/ticket.txt" "$work/prior.txt" "$work/prompt.txt" "$checkout" "$work/others.txt"

  if [ "$DRY_RUN" = true ]; then
    engine_dry_run "$work" "$slug" "$pr" "$head" "$base" "$provider"
    rm -rf "$work"; return 0
  fi

  # 5. run the model
  job_phase reviewing
  if ! findings_run "$provider" "$work/prompt.txt" "${checkout:-$work}" "$work/norm.json" "$work/raw"; then
    local kind="${GOBLIN_P_ERRKIND:-other}"
    log "  #$pr: review failed ($kind) ${GOBLIN_P_ERRMSG:-}"
    # A cancel kills the model mid-run, which surfaces here as an ordinary failure.
    # It is not one: it must not be recorded, retried-around or notified.
    if job_cancel_requested; then rm -rf "$work"; return 130; fi
    # Keep the evidence. Without this a failure is unreproducible — you'd have
    # to pay for another review just to see what the model actually said.
    rm -rf "$GOBLIN_HOME/last-failure"
    cp -R "$work" "$GOBLIN_HOME/last-failure" 2>/dev/null \
      && log "  #$pr: raw output kept at $GOBLIN_HOME/last-failure"
    events_append failed "$pr" "$title" "$url" "${GOBLIN_P_COST_USD:-0}" "$kind" "$slug" "$provider" "${GOBLIN_P_MODEL:-}"
    notify failed "$GOBLIN_NAME failed ⚠️" "#$pr — $kind"
    gh_status "$slug" "$head" error "review failed: $kind"
    attempt_record "${pr}:${head}" "$kind"
    status_set '{"state":"idle","activity":""}'
    job_phase failed "$(jq -nc --arg k "$kind" --arg m "${GOBLIN_P_ERRMSG:-}" '{error:$k, errorDetail:$m}')"
    rm -rf "$work"; return 1
  fi

  # 5b. a second, skeptical look — only where nobody reads the review before it posts
  if [ "$PREVIEW" != true ] && [ "$(cfg_get '.refutePass' true)" = "true" ]; then
    refute_run "$provider" "$work" "$checkout" "$pr" || true
  fi

  # 6. drop findings that were already posted and still stand
  if [ -s "$prior_json" ] && [ "$(jq 'length' "$prior_json")" != "0" ]; then
    jq --slurpfile prior "$prior_json" \
      '.findings |= map(select(. as $f | ($prior[0] | map(.id) | index($f.id)) == null))' \
      "$work/norm.json" > "$work/norm2.json" 2>/dev/null && mv "$work/norm2.json" "$work/norm.json"
  fi

  if [ "$PREVIEW" = true ]; then
    engine_save_preview "$work" "$slug" "$pr" "$head" "$base" "$title" "$url" "$provider" "$prior_json"
    local prc=$?
    rm -rf "$work"
    return $prc
  fi

  # 7. an unattended review either posts, or waits for a person (autoPost)
  if [ -z "${GOBLIN_JOB_ID:-}" ] && engine_should_hold "$work/norm.json"; then
    engine_hold "$work" "$slug" "$pr" "$head" "$base" "$title" "$url" "$provider" "$prior_json"
    local hrc=$?
    rm -rf "$work"
    return $hrc
  fi

  engine_publish "$work" "$slug" "$pr" "$head" "$base" "$title" "$url" "$provider" "$prior_json"
  local rc=$?
  rm -rf "$work"
  return $rc
}

# engine_save_preview — everything `goblin post` needs to publish this review later,
# plus one self-describing file (preview/review.json) for a person or the app to read.
#
# What is saved is the model's normalised output and the diff facts, not a rendered
# body: the body is rebuilt at post time so that edits made in between (dropping a
# finding, re-grading one) flow through the same renderer and the same verdict
# policy as an unattended review. There is no second path that posts differently.
engine_save_preview() {
  local work="$1" slug="$2" pr="$3" head="$4" base="$5" title="$6" url="$7" provider="$8" prior_json="$9"
  local model="${GOBLIN_P_MODEL:-$provider}" cost="${GOBLIN_P_COST_USD:-0}"
  local out="${GOBLIN_JOB_DIR:-$GOBLIN_HOME/last-preview}/preview"
  rm -rf "$out"; mkdir -p "$out" || return 1

  diff_split_findings "$work/norm.json" "$work/addr.json" "$work/split.json"
  cp "$work/norm.json" "$out/norm.json"
  cp "$work/addr.json" "$out/addr.json"
  cp "$work/files.json" "$out/files.json"
  cp "$prior_json" "$out/prior.json" 2>/dev/null || echo '[]' > "$out/prior.json"
  jq -nc --arg slug "$slug" --argjson pr "$pr" --arg head "$head" --arg base "$base" \
     --arg title "$title" --arg url "$url" --arg provider "$provider" --arg model "$model" \
     --argjson cost "${cost:-0}" '{slug:$slug, pr:$pr, head:$head, base:$base, title:$title,
       url:$url, provider:$provider, model:$model, costUsd:$cost}' > "$out/meta.json"

  # The file a human reads. `anchored` says whether GitHub will accept the comment on
  # a diff line; the rest ride in the body, exactly as they would if posted unedited.
  jq -n --slurpfile n "$work/norm.json" --slurpfile s "$work/split.json" \
        --slurpfile m "$out/meta.json" --slurpfile f "$work/files.json" '
    ($s[0].inline | map(.id)) as $inl
    | $m[0] + {
        summary: ($n[0].summary // ""),
        intent: ($n[0].intent_note // null),
        assessment: ($n[0].assessment // null),
        suggestedVerdict: ($n[0].suggested_verdict // "comment"),
        files: ($f[0] | length),
        additions: ([$f[0][].additions] | add // 0),
        deletions: ([$f[0][].deletions] | add // 0),
        findings: [ $n[0].findings[] | . + { anchored: (.id as $i | ($inl | index($i)) != null) } ]
      }' > "$out/review.json"

  local counts; counts="$(render_counts "$work/norm.json")"
  events_append previewed "$pr" "$title" "$url" "$cost" "" "$slug" "$provider" "$model"
  log "  #$pr: preview ready — $counts"
  notify posted "$GOBLIN_NAME finished 👺" "#$pr is ready to read — $counts"
  job_phase ready "$(jq -nc --arg c "$counts" --argjson n "$(jq '.findings|length' "$work/norm.json")" \
    --argjson cost "${cost:-0}" '{result:{counts:$c, findings:$n, costUsd:$cost}}')"
  status_set '{"state":"idle","activity":""}'
  return 0
}

# engine_should_hold <norm.json> — should this unattended review wait for a person?
#   autoPost = always  post everything (the original behaviour)
#              safe    post on its own only when nothing in it is a blocker and the
#                      model did not rate the change high-risk; otherwise hold it
#              never   hold every review: the scheduler finds and prepares, you post
# Sets ENGINE_HOLD_WHY for the log and the notification.
ENGINE_HOLD_WHY=""
engine_should_hold() {
  local norm="$1" policy
  policy="$(cfg_get '.autoPost' always)"
  case "$policy" in
    never) ENGINE_HOLD_WHY="every review waits for you (Settings › Behaviour)"; return 0 ;;
    safe)
      if jq -e '[.findings[]? | select(.severity == "blocker")] | length > 0' "$norm" >/dev/null 2>&1; then
        ENGINE_HOLD_WHY="it has a blocker"; return 0
      fi
      if jq -e '(.assessment.risk // "") == "high"' "$norm" >/dev/null 2>&1; then
        ENGINE_HOLD_WHY="the change looks high-risk"; return 0
      fi
      return 1 ;;
    *) return 1 ;;
  esac
}

# engine_hold — turn an unattended review into a job waiting in "Ready to read",
# exactly like a review asked for by number in preview mode: the same preview files,
# the same Post / Discard, the same `goblin post`. The PR is ledgered, so the scheduler
# does not review this commit again while it waits.
#
# With a fleet: nothing is posted while it waits, so after takeoverGraceSecs a
# teammate's goblin may review the PR itself. Post or discard within the grace period.
engine_hold() {
  local work="$1" slug="$2" pr="$3" head="$4" base="$5" title="$6" url="$7" provider="$8" prior_json="$9"
  local id dir author rc
  id="$(job_new_id)"; dir="$(job_dir_of "$id")"
  mkdir -p "$dir" || return 1
  author="$(jq -r '.author // ""' "$work/pr.json" 2>/dev/null)"
  job_write "$id" "$(jq -nc --arg id "$id" --arg repo "$slug" --argjson n "$pr" --arg t "$title" \
    --arg u "$url" --arg prov "$provider" --arg model "${GOBLIN_P_MODEL:-}" --arg head "$head" \
    --arg author "$author" --arg why "$ENGINE_HOLD_WHY" --argjson at "$(now_epoch)" \
    '{id:$id, repo:$repo, number:$n, title:$t, url:$u, phase:"reviewing", mode:"preview",
      origin:"scheduled", heldBecause:$why, provider:$prov, providerUsed:$prov, model:$model,
      focus:"full", force:false, head:$head, author:$author, createdAt:$at}')" || return 1

  GOBLIN_JOB_ID="$id"; GOBLIN_JOB_DIR="$dir"
  engine_save_preview "$work" "$slug" "$pr" "$head" "$base" "$title" "$url" "$provider" "$prior_json"; rc=$?
  # The scheduler goes on to other PRs in this same process: nothing after this may
  # think it is still inside this job.
  GOBLIN_JOB_ID=""; GOBLIN_JOB_DIR=""
  [ "$rc" -eq 0 ] || return "$rc"

  ledger_add "${pr}:${head}"
  attempt_clear "${pr}:${head}" 2>/dev/null || true
  REVIEWS_THIS_RUN=$((REVIEWS_THIS_RUN + 1))
  gh_status "$slug" "$head" success "review ready — waiting for @${GOBLIN_LOGIN:-you} to post it" 2>/dev/null || true
  log "  #$pr: held for you to read — $ENGINE_HOLD_WHY"
  notify posted "$GOBLIN_NAME is holding #$pr 👺" "Not posted: $ENGINE_HOLD_WHY. Read it, then post or discard."
  return 0
}

engine_publish() {
  local work="$1" slug="$2" pr="$3" head="$4" base="$5" title="$6" url="$7" provider="$8" prior_json="$9"
  local model="${GOBLIN_P_MODEL:-$provider}" cost="${GOBLIN_P_COST_USD:-0}"

  diff_split_findings "$work/norm.json" "$work/addr.json" "$work/split.json"
  local event; event="$(findings_verdict "$work/norm.json")"
  render_review_body "$work/norm.json" "$work/split.json" "$pr" "$head" "$base" \
                     "$provider" "$model" "$GOBLIN_LOGIN" "$work/files.json" "$event" > "$work/body.md"
  if ! post_build_review "$work/split.json" "$work/body.md" "$head" "$event" \
                         "$provider" "$model" "$pr" "$work/review.json"; then
    events_append failed "$pr" "$title" "$url" "$cost" "payload incomplete" "$slug" "$provider" "$model"
    notify failed "$GOBLIN_NAME failed ⚠️" "#$pr — review payload was incomplete"
    gh_status "$slug" "$head" error "review payload was incomplete"
    attempt_record "${pr}:${head}" "payload"
    job_phase failed '{"error":"payload","errorDetail":"The review payload was incomplete, so nothing was posted."}'
    return 1
  fi

  # Second liveness check. The model run above takes a minute or two, which is
  # long enough on this repo for the PR to merge underneath us.
  if ! gh_pr_is_open "$slug" "$pr"; then
    log "  #$pr: merged or closed during the review — not posting"
    ledger_add "${pr}:${head}"
    status_set '{"state":"idle","activity":""}'
    job_phase skipped '{"reason":"closed"}'
    return 0
  fi

  job_phase posting
  local review_url
  if ! review_url="$(post_review "$slug" "$pr" "$work/review.json" "$work/err.json")"; then
    log "  #$pr: posting failed — $(head -c 200 "$work/err.json" 2>/dev/null)"
    events_append failed "$pr" "$title" "$url" "$cost" "post failed" "$slug" "$provider" "$model"
    notify failed "$GOBLIN_NAME failed ⚠️" "#$pr — could not post review"
    gh_status "$slug" "$head" error "could not post review"
    attempt_record "${pr}:${head}" "post"
    job_phase failed '{"error":"post","errorDetail":"GitHub rejected the review."}'
    return 1
  fi

  # the second comment: does this do what the ticket asked?
  local intent; intent="$(jq -c '.intent_note // empty' "$work/norm.json" 2>/dev/null)"
  if [ -n "$intent" ] && [ "$(printf '%s' "$intent" | jq -r '.verdict')" != "no_ticket" ]; then
    render_intent_body "$intent" "$pr" "$head" "$provider" "$model" "$GOBLIN_LOGIN" > "$work/intent.md"
    post_intent "$slug" "$pr" "$work/intent.md"
  fi

  # tell prior threads that their finding is gone
  if [ -s "$prior_json" ] && [ "$(jq 'length' "$prior_json")" != "0" ]; then
    jq -c '[.findings[].id]' "$work/norm.json" > "$work/curids.json"
    post_fixed_replies "$slug" "$pr" "$prior_json" "$work/curids.json" "$head"
  fi

  local counts inline_n
  counts="$(render_counts "$work/norm.json")"
  inline_n="$(jq '.inline | length' "$work/split.json")"
  gh_status "$slug" "$head" success "$counts · $model" "$review_url"
  GOBLIN_LAST_REVIEW_URL="$review_url"
  job_phase done "$(jq -nc --arg c "$counts" --arg u "$review_url" --argjson n "${inline_n:-0}" \
    --argjson cost "${cost:-0}" '{result:{counts:$c, reviewUrl:$u, inline:$n, costUsd:$cost}}')"

  ledger_add "${pr}:${head}"
  attempt_clear "${pr}:${head}"
  events_append posted "$pr" "$title" "$url" "$cost" "" "$slug" "$provider" "$model"
  REVIEWS_THIS_RUN=$((REVIEWS_THIS_RUN + 1))
  log "  #$pr: posted — $counts ($inline_n inline)${cost:+, \$$cost}"
  notify posted "$GOBLIN_NAME posted ✅" "#$pr — $counts"
  status_set '{"state":"idle","activity":""}'
  return 0
}

engine_dry_run() {
  local work="$1" slug="$2" pr="$3" head="$4" base="$5" provider="$6"
  echo
  echo "── dry run: $slug#$pr @ $(trunc "$head" 7) ────────────────────"
  echo "provider:          $provider"
  echo "prompt:            $(wc -c < "$work/prompt.txt" | tr -d ' ') bytes  ($work/prompt.txt)"
  echo "diff:              $(wc -c < "$work/diff.txt" | tr -d ' ') bytes, $(jq 'length' "$work/files.json") files"
  echo "addressable lines: $(jq 'length' "$work/addr.json")"
  local rf; rf="$(prompt_discover "$work/rules" "$slug" 2>/dev/null || true)"
  echo "review rules from: ${rf:+${rf#"$work"/rules/} (origin/$base)}${rf:-(built-in fallback)}"
  echo "ticket context:    $([ -s "$work/ticket.txt" ] && echo "$(wc -c < "$work/ticket.txt" | tr -d ' ') bytes" || echo none)"
  echo "verdict would be:  $(cfg_get '.verdictMode' comment) → (computed after findings)"
  echo
  echo "no model was called and nothing was posted."
  echo "to see the assembled prompt:  less $work/prompt.txt"
  # Keep the workdir for inspection. Remove any previous copy first: `cp -R src
  # dst` nests src INSIDE dst when dst already exists, which silently leaves the
  # stale run in place.
  rm -rf "$GOBLIN_HOME/last-dry-run"
  cp -R "$work" "$GOBLIN_HOME/last-dry-run" 2>/dev/null && echo "copy kept at: $GOBLIN_HOME/last-dry-run"
}

# Standalone clone (never a worktree under ~/Documents — macOS TCC blocks
# launchd from reading there), reset hard before every checkout because leftover
# dirty files made `gh pr checkout` abort on every PR once.
# engine_git <git args...> — git that can neither prompt nor hang. A credential prompt
# under launchd has nobody to answer it, and a stalled fetch would otherwise hold the
# repo lock (and the whole run) until the stale-lock sweep.
engine_git() {
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true \
    run_with_timeout "$(cfg_get '.gitTimeoutSecs' 120)" git "$@"
}

# Symlinks in a pull request's checkout can point anywhere on this machine, and the
# model is about to be handed read access to that directory. Delete them all; the
# files they point at are still readable by their real names.
engine_scrub_symlinks() {
  find "$1" -path "$1/.git" -prune -o -type l -exec rm -f {} + 2>/dev/null || true
}

engine_checkout() {
  local slug="$1" pr="$2" dir="$3"
  # `rev-parse --git-dir` alone is true for any directory INSIDE some other work tree, and
  # a reset --hard there would run against that other repository.
  if [ ! -d "$dir" ] || [ "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" != "$(cd "$dir" 2>/dev/null && pwd -P)" ]; then
    log "  cloning $slug (one-time)"
    rm -rf "$dir"
    engine_git clone --quiet "https://github.com/$slug.git" "$dir" >/dev/null 2>&1 || return 1
  fi
  engine_git -C "$dir" fetch --quiet origin >/dev/null 2>&1 || return 1
  git -C "$dir" reset --hard --quiet >/dev/null 2>&1
  git -C "$dir" clean -ffd >/dev/null 2>&1
  # GitHub keeps refs/pull/N/head for every PR, open, merged or from a fork. `gh pr
  # checkout` goes by branch name instead, which fails once the branch is deleted —
  # exactly the PR someone asks to have reviewed after the fact — so it is only the
  # fallback.
  if engine_git -C "$dir" fetch --quiet origin "pull/$pr/head" >/dev/null 2>&1 \
     && git -C "$dir" checkout --quiet --detach FETCH_HEAD >/dev/null 2>&1; then
    engine_scrub_symlinks "$dir"
    return 0
  fi
  ( cd "$dir" && run_with_timeout "$(cfg_get '.gitTimeoutSecs' 120)" gh pr checkout "$pr" --repo "$slug" --detach >/dev/null 2>&1 ) || return 1
  engine_scrub_symlinks "$dir"
  return 0
}
