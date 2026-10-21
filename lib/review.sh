#!/usr/bin/env bash
# review.sh — review one pull request on demand: `goblin review 2456`.
#
#   goblin review <ref> [options]    start a review (a "job")
#   goblin post <job> [--edits F]    publish a review that is waiting in preview
#   goblin cancel <job>              stop a running job, or discard a waiting review
#   goblin jobs [--json] [prune]     what has been asked for, newest first
#   goblin job <job> [--json]        one job, with its preview if it has one
#   goblin resolve <ref> [--repo S]  what would this ref mean? (no review)
#
# <ref> is `2456`, `#2456`, `owner/repo#2456` or a PR URL. A bare number needs a repo,
# found in this order: --repo, the repo of the current directory, the last repo you
# reviewed, the only repo you watch.
#
# A manual review defaults to PREVIEW: the whole review runs, nothing is sent to
# GitHub, and the result waits for you to read it (and edit it) before `goblin post`.
# That default exists because the review posts under your own name.

# --- refs --------------------------------------------------------------------

# The owner starts with a letter or digit (GitHub's own rule), so a slug can never be
# read as an option.
REF_SLUG_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9._-]{1,100}$'

# ref_parse <ref> → "slug|number" (slug may be empty), or non-zero if it is not a ref.
ref_parse() {
  local r="$1" slug="" num="" p
  # trim
  r="${r#"${r%%[![:space:]]*}"}"; r="${r%"${r##*[![:space:]]}"}"
  case "$r" in
    *github.com/*)
      p="${r#*github.com/}"; p="${p%%\?*}"; p="${p%%#*}"
      slug="$(printf '%s' "$p" | awk -F/ '$3=="pull" {print $1 "/" $2}')"
      num="$(printf '%s' "$p"  | awk -F/ '$3=="pull" {print $4}')" ;;
    *#*) slug="${r%%#*}"; num="${r##*#}" ;;
    *)   num="$r" ;;
  esac
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#num}" -le 7 ] || return 1
  num=$((10#$num)); [ "$num" -ge 1 ] || return 1
  if [ -n "$slug" ]; then printf '%s' "$slug" | grep -qE "$REF_SLUG_RE" || return 1; fi
  printf '%s|%s' "$slug" "$num"
}

# The owner/name of the GitHub remote in the current directory, if there is one.
ref_cwd_repo() {
  local u
  u="$(git remote get-url origin 2>/dev/null)" || return 1
  u="$(printf '%s' "$u" | sed -E 's#^(git@|ssh://git@|https?://)(www\.)?github\.com[:/]##; s#\.git$##; s#/$##')"
  printf '%s' "$u" | grep -qE "$REF_SLUG_RE" || return 1
  printf '%s' "$u"
}

# ref_candidates — repos worth offering when a bare number is ambiguous.
ref_candidates() {
  jq -nc --arg last "$(cfg_get '.lastRepo' '')" \
        --argjson watched "$(cfg_get_json '[.repos[]?.slug]' '[]')" \
    '([$last] + $watched) | map(select(. != "")) | unique'
}

# ref_repo_resolve <slug-from-ref> <repo-flag> → prints a slug, or returns 3.
ref_repo_resolve() {
  local s="$1" flag="$2" r last n
  if [ -n "$s" ]; then printf '%s' "$s"; return 0; fi
  if [ -n "$flag" ]; then
    printf '%s' "$flag" | grep -qE "$REF_SLUG_RE" || return 2
    printf '%s' "$flag"; return 0
  fi
  r="$(ref_cwd_repo)" && { printf '%s' "$r"; return 0; }
  last="$(cfg_get '.lastRepo' '')"
  [ -n "$last" ] && { printf '%s' "$last"; return 0; }
  n="$(cfg_repos_enabled | grep -c .)"
  if [ "${n:-0}" -eq 1 ]; then cfg_repos_enabled | head -1 | tr -d '\n'; return 0; fi
  return 3
}

# Shared by review and resolve. Sets REF_SLUG and REF_NUM, or prints the failure
# and returns 2 (unusable) / 3 (needs a repo).
ref_resolve_or_fail() {
  local ref="$1" repo_flag="$2" json="$3" parsed s slug rc
  if ! parsed="$(ref_parse "$ref")"; then
    ref_fail "$json" bad_ref "\"$ref\" is not a pull request. Try 2456, owner/repo#2456 or a PR URL."; return 2
  fi
  s="${parsed%%|*}"; REF_NUM="${parsed##*|}"
  slug="$(ref_repo_resolve "$s" "$repo_flag")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 3 ]; then
      ref_fail "$json" needs_repo "Which repo is #$REF_NUM in? Pass --repo owner/name." "$(ref_candidates)"; return 3
    fi
    ref_fail "$json" bad_repo "\"$repo_flag\" is not an owner/name repo."; return 2
  fi
  REF_SLUG="$slug"
}

ref_fail() { # <json?> <code> <message> [candidates-json]
  if [ "$1" = true ]; then
    jq -nc --arg c "$2" --arg m "$3" --argjson cand "${4:-[]}" \
      '{ok:false, error:$c, message:$m, candidates:$cand}'
  else
    echo "goblin: $3" >&2
  fi
}

# --- commands ----------------------------------------------------------------

cmd_resolve() {
  local ref="" repo="" json=true
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
      --plain) json=false; shift ;;
      --json) json=true; shift ;;
      -*) echo "goblin resolve: unknown option $1" >&2; return 2 ;;
      *) ref="$1"; shift ;;
    esac
  done
  [ -n "$ref" ] || { echo "usage: goblin resolve <ref> [--repo owner/name]" >&2; return 2; }
  cfg_ensure
  ref_resolve_or_fail "$ref" "$repo" "$json" || return $?
  engine_auth_lite || { ref_fail "$json" auth "GitHub is not signed in as the configured account."; return 1; }
  local f="$RUNTMP/resolve-$$.json"; mkdir -p "$RUNTMP"
  if ! gh api "repos/$REF_SLUG/pulls/$REF_NUM" \
        --jq '{title, state, merged, draft, author: .user.login, url: .html_url, head: .head.sha, base: .base.ref}' \
        > "$f" 2>/dev/null || ! jq -e . "$f" >/dev/null 2>&1; then
    rm -f "$f"
    ref_fail "$json" not_found "$REF_SLUG#$REF_NUM was not found, or you cannot see it."; return 1
  fi
  if [ "$json" = true ]; then
    jq -c --arg r "$REF_SLUG" --argjson n "$REF_NUM" '{ok:true, repo:$r, number:$n} + .' "$f"
  else
    jq -r --arg r "$REF_SLUG" --argjson n "$REF_NUM" '"\($r)#\($n) — \(.title) (\(.state))"' "$f"
  fi
  rm -f "$f"
}

cmd_review() {
  local ref="" repo="" mode="" force=false provider="" model="" focus=full detach=false json=false run_job=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)     repo="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
      --post)     mode=post; shift ;;
      --preview)  mode=preview; shift ;;
      --force)    force=true; shift ;;
      --provider) provider="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
      --model)    model="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
      --focus)    focus="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
      --detach)   detach=true; shift ;;
      --json)     json=true; shift ;;
      --run-job)  run_job="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
      -*) echo "goblin review: unknown option $1" >&2; return 2 ;;
      *)  ref="$1"; shift ;;
    esac
  done

  cfg_ensure; cfg_backfill_defaults; goblin_ensure_dirs

  # The detached half: a job already exists, this process is its worker.
  if [ -n "$run_job" ]; then
    job_id_ok "$run_job" && [ -f "$(job_dir_of "$run_job")/job.json" ] || return 2
    review_run_job "$run_job"; return $?
  fi

  [ -n "$ref" ] || { echo "usage: goblin review <ref> [--repo owner/name] [--post|--preview] [--force] [--focus full|security|summary] [--provider P] [--model M] [--detach] [--json]" >&2; return 2; }

  case "$focus" in full|security|summary) ;; *) ref_fail "$json" bad_option "--focus must be full, security or summary."; return 2 ;; esac
  if [ -n "$provider" ]; then
    case "$provider" in claude|codex|cursor) ;; *) ref_fail "$json" bad_option "unknown provider \"$provider\"."; return 2 ;; esac
  fi
  if [ -n "$model" ]; then
    printf '%s' "$model" | grep -qE '^[A-Za-z0-9._:-]{1,64}$' || { ref_fail "$json" bad_option "that is not a model name."; return 2; }
  fi
  [ -n "$mode" ] || mode="$(cfg_get '.manualReviewMode' preview)"
  case "$mode" in post|preview) ;; *) mode=preview ;; esac

  ref_resolve_or_fail "$ref" "$repo" "$json" || return $?

  local id dir
  id="$(job_new_id)"; dir="$(job_dir_of "$id")"
  mkdir -p "$dir" || return 1
  job_write "$id" "$(jq -nc --arg id "$id" --arg repo "$REF_SLUG" --argjson n "$REF_NUM" \
    --arg mode "$mode" --arg prov "$provider" --arg model "$model" --arg focus "$focus" \
    --argjson force "$force" --argjson at "$(now_epoch)" \
    '{id:$id, repo:$repo, number:$n, title:"", url:("https://github.com/" + $repo + "/pull/" + ($n|tostring)),
      phase:"queued", mode:$mode, provider:$prov, model:$model, focus:$focus, force:$force,
      createdAt:$at}')"
  cfg_set --arg r "$REF_SLUG" '.lastRepo = $r' 2>/dev/null || true

  if [ "$detach" = true ]; then
    nohup "$GOBLIN_APP/bin/goblin" review --run-job "$id" > "$dir/log.txt" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    if [ "$json" = true ]; then jq -c '. + {ok:true}' "$dir/job.json"; else echo "$id"; fi
    return 0
  fi

  review_run_job "$id"; local rc=$?
  if [ "$json" = true ]; then jq -c '. + {ok:true}' "$dir/job.json"; else review_print_outcome "$id"; fi
  return $rc
}

review_print_outcome() {
  local id="$1" dir ph
  dir="$(job_dir_of "$id")"; ph="$(job_get "$id" phase)"
  echo
  case "$ph" in
    ready)
      jq -r '"\(.slug)#\(.pr) — \(.title)\n\(.findings | length) finding(s) · \(.files) files, +\(.additions) −\(.deletions)\n\n\(.summary)\n"' "$dir/preview/review.json"
      jq -r '.findings[] | "  [\(.severity)] \(.path // "repo"):\(.line // "-")  \(.title)"' "$dir/preview/review.json"
      echo
      echo "nothing has been posted. read it, then:  goblin post $id"
      echo "or throw it away:                        goblin cancel $id" ;;
    done)      echo "posted: $(jq -r '.result.reviewUrl // ""' "$dir/job.json")" ;;
    skipped)   local why; why="$(job_get "$id" reasonDetail)"; [ -n "$why" ] || why="$(job_get "$id" reason)"
               echo "skipped: $why  (use --force to review anyway)" ;;
    cancelled) echo "cancelled" ;;
    *)         echo "failed: $(job_get "$id" error) $(job_get "$id" errorDetail)" ;;
  esac
}

REVIEW_JOB_CLEANED=false
review_job_cleanup() {
  [ "$REVIEW_JOB_CLEANED" = true ] && return 0
  REVIEW_JOB_CLEANED=true
  repo_lock_release; job_slot_release
  rm -rf "$RUNTMP"/pr-"${REVIEW_JOB_PR:-0}"-$$ 2>/dev/null
}
review_job_on_signal() {
  job_phase cancelled
  exit 130
}

# review_run_job <id> — the worker. Foreground for the CLI, detached for the app.
review_run_job() {
  local id="$1"
  GOBLIN_JOB_ID="$id"; GOBLIN_JOB_DIR="$(job_dir_of "$id")"
  local slug number mode provider_ov model_ov focus force
  slug="$(job_get "$id" repo)"; number="$(job_get "$id" number)"
  mode="$(job_get "$id" mode)"; provider_ov="$(job_get "$id" provider)"
  model_ov="$(job_get "$id" model)"; focus="$(job_get "$id" focus)"; force="$(job_get "$id" force)"
  REVIEW_JOB_PR="$number"

  job_write "$id" "$(jq -nc --argjson p "$$" '{pid:$p}')"
  trap 'review_job_on_signal' TERM INT HUP
  trap 'review_job_cleanup' EXIT

  if ! job_slot_acquire; then job_phase cancelled; return 130; fi

  # `engine_auth` also exports the git credential rewrite the clone needs.
  if ! engine_auth; then
    job_phase failed '{"error":"auth","errorDetail":"GitHub is not signed in as the configured account. Open Health and run the checks."}'
    return 1
  fi

  providers_load
  local provider
  if [ -n "$provider_ov" ]; then
    provider="$provider_ov"
    local probe; probe="$("provider_${provider}_probe" 2>/dev/null)"
    if [ "$(printf '%s' "$probe" | jq -r '.available and .authed' 2>/dev/null)" != "true" ]; then
      job_phase failed "$(jq -nc --arg p "$provider" '{error:"provider", errorDetail:($p + " is not installed or not signed in.")}')"
      return 1
    fi
  else
    provider="$(providers_pick)" || {
      job_phase failed '{"error":"provider","errorDetail":"No AI CLI is installed and signed in. Open Providers."}'
      return 1
    }
  fi
  # The repo's own provider/model (repos[].provider/.model) applies unless this review
  # named one. --provider wins outright; --model alone keeps the repo's provider.
  if [ -z "$provider_ov" ]; then
    engine_repo_provider "$slug" "$provider"
    provider="$ENGINE_REPO_PROVIDER"
    [ -z "$model_ov" ] && model_ov="$ENGINE_REPO_MODEL"
  elif [ -z "$model_ov" ] && [ "$(cfg_repo_field "$slug" provider '')" = "$provider_ov" ]; then
    model_ov="$(cfg_repo_field "$slug" model '')"
  fi
  # Applied to this process only (see cfg_read); never written back.
  GOBLIN_CFG_OVERLAY="$(jq -nc --arg p "$provider" --arg m "$model_ov" \
    '{provider:$p} + (if $m != "" then {providers:{($p):{model:$m}}} else {} end)')"
  export GOBLIN_CFG_OVERLAY
  job_write "$id" "$(jq -nc --arg p "$provider" '{providerUsed:$p}')"

  local meta="$GOBLIN_JOB_DIR/pr-meta.json"
  if ! gh_pr_meta "$slug" "$number" "$meta" || ! jq -e '.head' "$meta" >/dev/null 2>&1; then
    job_phase failed "$(jq -nc --arg s "$slug#$number" '{error:"not_found", errorDetail:($s + " was not found, or this account cannot see it.")}')"
    return 1
  fi
  local head title url base
  head="$(jq -r '.head' "$meta")"; title="$(jq -r '.title' "$meta")"
  url="$(jq -r '.url' "$meta")"; base="$(jq -r '.base' "$meta")"
  job_write "$id" "$(jq -nc --arg t "$title" --arg u "$url" --arg h "$head" --arg a "$(jq -r '.author' "$meta")" \
    '{title:$t, url:$u, head:$h, author:$a}')"

  # Reviewing a PR that has already merged posts advice nobody reads; and a commit the
  # Goblin already reviewed would double-post. Both are the user's call to override.
  if [ "$force" != "true" ]; then
    if ! gh_pr_is_open "$slug" "$number"; then
      job_phase skipped '{"reason":"closed"}'; return 0
    fi
    local prior psha
    prior="$(gh_prior_review "$slug" "$number")"
    if [ -n "$prior" ]; then
      psha="$(printf '%s' "$prior" | jq -r '.m.headSha // ""')"
      if [ "$psha" = "$head" ]; then
        job_phase skipped '{"reason":"already_reviewed"}'; return 0
      fi
    fi
    # Noise: a dependency bot's PR, only lockfiles/generated files, or (if enabled) only
    # docs. Asked for by number it is still the person's call, hence --force.
    local skipj
    if skipj="$(skip_check "$slug" "$number" "$(jq -r '.author // ""' "$meta")" "$GOBLIN_JOB_DIR/skip-files.json")"; then
      log "job $id: skipped — $(printf '%s' "$skipj" | jq -r '.detail')"
      job_phase skipped "$(printf '%s' "$skipj" | jq -c '{reason, reasonDetail: .detail}')"
      return 0
    fi
  fi
  local last_sha=""
  last_sha="$(gh_prior_review "$slug" "$number" | jq -r '.m.headSha // ""' 2>/dev/null)"

  ONLY_PR="$number"; DRY_RUN=false; FORCE="$force"
  PREVIEW=false; [ "$mode" = preview ] && PREVIEW=true
  GOBLIN_FOCUS="$focus"; export GOBLIN_FOCUS

  log "job $id: $slug#$number ($mode, $provider${model_ov:+/$model_ov}, $focus)"
  engine_review_pr "$slug" "$number" "$head" "$title" "$url" "$base" "$provider" "$last_sha"
  local rc=$?

  # The engine sets a terminal phase on every path it knows about. If it returned
  # without one, say so rather than leaving the job spinning.
  local ph; ph="$(job_get "$id" phase)"
  case " $JOB_ACTIVE_PHASES " in
    *" $ph "*)
      if [ "$rc" -eq 130 ] || job_cancel_requested; then job_phase cancelled
      elif [ "$rc" -ne 0 ]; then job_phase failed '{"error":"other","errorDetail":"The review did not finish."}'
      else job_phase failed '{"error":"other","errorDetail":"The review ended without a result."}'
      fi ;;
  esac
  return $rc
}

cmd_post() {
  local id="" edits="" json=false force=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --edits) edits="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
      # The app writes jobs/<id>/edits.json itself and names no path: nothing a UI
      # could be talked into passing can point this at some other file.
      --saved-edits) edits="@saved"; shift ;;
      --json)  json=true; shift ;;
      --force) force=true; shift ;;
      -*) echo "goblin post: unknown option $1" >&2; return 2 ;;
      *) id="$1"; shift ;;
    esac
  done
  job_id_ok "$id" || { echo "usage: goblin post <job> [--edits file.json]" >&2; return 2; }
  local dir; dir="$(job_dir_of "$id")"
  [ -f "$dir/preview/norm.json" ] || { echo "goblin: job $id has no review waiting" >&2; return 1; }
  local ph; ph="$(job_get "$id" phase)"
  case "$ph" in ready|failed) ;; *) echo "goblin: job $id is $ph, not waiting to be posted" >&2; return 1 ;; esac

  cfg_ensure; goblin_ensure_dirs
  if [ "$edits" = "@saved" ]; then
    edits="$dir/edits.json"; [ -f "$edits" ] || edits=""
  fi
  GOBLIN_JOB_ID="$id"; GOBLIN_JOB_DIR="$dir"
  job_write "$id" "$(jq -nc --argjson p "$$" '{pid:$p, error:"", errorDetail:""}')"
  job_phase posting
  trap 'job_phase ready; exit 130' TERM INT HUP

  if ! engine_auth; then
    job_phase failed '{"error":"auth","errorDetail":"GitHub is not signed in as the configured account."}'
    return 1
  fi

  local work="$RUNTMP/post-$$"; rm -rf "$work"; mkdir -p "$work"
  cp "$dir/preview/norm.json" "$work/norm.json"
  cp "$dir/preview/addr.json" "$work/addr.json"
  cp "$dir/preview/files.json" "$work/files.json"
  if [ -n "$edits" ]; then
    if ! review_apply_edits "$work/norm.json" "$edits"; then
      job_phase ready '{"error":"bad_edits","errorDetail":"The edits could not be applied."}'
      rm -rf "$work"; return 2
    fi
  fi

  local slug pr head base title url provider
  slug="$(jq -r '.slug' "$dir/preview/meta.json")";  pr="$(jq -r '.pr' "$dir/preview/meta.json")"
  head="$(jq -r '.head' "$dir/preview/meta.json")";  base="$(jq -r '.base' "$dir/preview/meta.json")"
  title="$(jq -r '.title' "$dir/preview/meta.json")"; url="$(jq -r '.url' "$dir/preview/meta.json")"
  provider="$(jq -r '.provider' "$dir/preview/meta.json")"
  GOBLIN_P_MODEL="$(jq -r '.model' "$dir/preview/meta.json")"
  # Already counted when the preview was produced; counting it twice would double the
  # spend shown for a single review.
  GOBLIN_P_COST_USD=0

  # A preview can sit for hours. If a review of this exact commit was posted AFTER this
  # preview was made (the scheduler, a teammate's goblin, or this same preview posted
  # from another window), posting it again is a duplicate. A review posted BEFORE the
  # preview was made is not: that is somebody deliberately asking for a fresh look.
  if [ "$force" != true ] && review_posted_since "$slug" "$pr" "$head" "$(job_get "$id" createdAt)"; then
    job_phase ready '{"error":"already_posted","errorDetail":"A review of this exact commit was posted after this preview was made, so posting it would duplicate it. Discard it, or post anyway with goblin post --force."}'
    rm -rf "$work"
    if [ "$json" = true ]; then jq -c '. + {ok:false}' "$dir/job.json"; else echo "goblin: this commit was already reviewed after the preview was made — not posting a duplicate (use --force to post anyway)" >&2; fi
    return 1
  fi

  local now_head
  now_head="$(gh api "repos/$slug/pulls/$pr" --jq .head.sha 2>/dev/null)"
  if [ -n "$now_head" ] && [ "$now_head" != "$head" ]; then
    log "job $id: the PR moved on since the review ($(trunc "$head" 7) → $(trunc "$now_head" 7)); posting against the commit that was reviewed"
    job_write "$id" '{"headChanged":true}'
  fi

  PREVIEW=false
  engine_publish "$work" "$slug" "$pr" "$head" "$base" "$title" "$url" "$provider" "$dir/preview/prior.json"
  local rc=$?
  rm -rf "$work"
  # engine_publish reports done/failed/skipped itself; make sure nothing is left mid-post.
  ph="$(job_get "$id" phase)"
  [ "$ph" = posting ] && job_phase failed '{"error":"other","errorDetail":"Posting did not finish."}'
  if [ "$json" = true ]; then jq -c '. + {ok:true}' "$dir/job.json"; else review_print_outcome "$id"; fi
  return $rc
}

# review_posted_since <slug> <pr> <head> <epoch> — true when one of our (or the fleet's)
# reviews of <head> was submitted after <epoch>. Fails open: if GitHub can't be read,
# the post goes ahead rather than being blocked by a check that could not run.
review_posted_since() {
  local slug="$1" pr="$2" head="$3" since="${4:-0}" prior iso
  case "$since" in ''|*[!0-9]*) return 1 ;; esac
  [ "$since" -gt 0 ] || return 1
  iso="$(date -u -r "$since" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$since" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  [ -n "$iso" ] || return 1
  prior="$(gh_prior_review "$slug" "$pr")"
  [ -n "$prior" ] || return 1
  printf '%s' "$prior" | jq -e --arg h "$head" --arg t "$iso" \
    '(.m.headSha // "") == $h and (.submitted_at // "") > $t' >/dev/null 2>&1
}

# review_apply_edits <norm.json> <edits.json>
#   { "drop": ["<finding id>"], "edit": {"<id>": {"severity","title","body","suggestion"}},
#     "summary": "..." }
# Unknown keys and unknown severities are refused: an edit file that does not mean what
# its author thinks it means must not silently post.
review_apply_edits() {
  local norm="$1" edits="$2"
  jq -e '
    type == "object"
    and ((keys - ["drop","edit","summary"]) | length == 0)
    and ((.drop // []) | type == "array" and all(type == "string"))
    and ((.edit // {}) | type == "object"
         and all(.[]; type == "object"
                 and ((keys - ["severity","title","body","suggestion"]) | length == 0)
                 and ((.severity // "nit") | IN("blocker","convention","risk","nit","question"))
                 and ((.title // "x") | type == "string" and length > 0)
                 and ((.body // "x") | type == "string" and length > 0)
                 and ((.suggestion // "x") | type == "string")))
    and ((.summary // "") | type == "string")' "$edits" >/dev/null 2>&1 || return 1
  jq --slurpfile e "$edits" '
    ($e[0].drop // []) as $drop | ($e[0].edit // {}) as $ed
    | ["blocker","convention","risk","nit","question"] as $order
    | .findings |= ( map(select(.id as $i | ($drop | index($i)) | not))
                     | map(if $ed[.id] then . + ($ed[.id] | with_entries(select(.value != null))) else . end)
                     | sort_by(.severity as $s | $order | index($s)) )
    | if ($e[0].summary // "") != "" then .summary = $e[0].summary else . end' \
    "$norm" > "$norm.t" && mv "$norm.t" "$norm"
}

cmd_cancel() {
  local id="${1:-}"
  job_id_ok "$id" || { echo "usage: goblin cancel <job>" >&2; return 2; }
  local dir ph pid; dir="$(job_dir_of "$id")"
  [ -f "$dir/job.json" ] || { echo "goblin: no such job" >&2; return 1; }
  GOBLIN_JOB_ID="$id"; GOBLIN_JOB_DIR="$dir"
  ph="$(job_get "$id" phase)"; pid="$(job_get "$id" pid)"
  case "$ph" in
    ready|failed) job_phase discarded; return 0 ;;
  esac
  case " $JOB_ACTIVE_PHASES " in *" $ph "*) ;; *) return 0 ;; esac
  : > "$dir/cancel"
  if job_alive "$pid"; then
    local p
    # Descendants first, then the worker: the flag is already set, so whatever dies
    # first is read as a cancel, never as a failure.
    for p in $(job_tree "$pid"); do kill -TERM "$p" 2>/dev/null; done
    local i=0
    while [ "$i" -lt 30 ] && job_alive "$pid"; do sleep 0.1; i=$((i + 1)); done
    job_alive "$pid" && kill -KILL "$pid" 2>/dev/null
  fi
  ph="$(job_get "$id" phase)"
  case " $JOB_ACTIVE_PHASES " in *" $ph "*) job_phase cancelled ;; esac
  return 0
}

cmd_jobs() {
  local json=false limit=50
  case "${1:-}" in
    prune) jobs_prune; return 0 ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=true; shift ;;
      --limit) limit="${2:-50}"; shift $(( $# > 1 ? 2 : 1 )) ;;
      *) shift ;;
    esac
  done
  case "$limit" in ''|*[!0-9]*) limit=50 ;; esac
  cfg_ensure; goblin_ensure_dirs
  if [ "$json" = true ]; then jobs_list_json "$limit"; return 0; fi
  jobs_list_json "$limit" | jq -r '.[] | "\(.id)  \(.phase | . + (" " * (10 - length)))  \(.repo)#\(.number)  \(.title)"'
}

cmd_job() {
  local id="${1:-}" json=false
  [ "${2:-}" = "--json" ] && json=true
  job_id_ok "$id" || { echo "usage: goblin job <job> [--json]" >&2; return 2; }
  local dir; dir="$(job_dir_of "$id")"
  [ -f "$dir/job.json" ] || { echo "goblin: no such job" >&2; return 1; }
  job_reconcile "$id"
  if [ "$json" = true ]; then
    jq -c --slurpfile r "${dir}/preview/review.json" '{job: ., review: $r[0]}' "$dir/job.json" 2>/dev/null \
      || jq -c '{job: ., review: null}' "$dir/job.json"
  else
    review_print_outcome "$id"
  fi
}
