#!/usr/bin/env bash
# refute.sh — a second, skeptical pass over the findings before they are posted.
#
# Models over-report and over-grade: a first pass will happily call a missing test a
# blocker. A second call, whose only job is to disprove each finding against the real
# source, is the cheapest filter there is. It runs on reviews that post WITHOUT a person
# reading them first (the scheduler, and manual --post); a preview already has a human in
# the loop, so it is skipped there. It fails open: if the check itself fails, the findings
# stand as they were, because a broken second opinion must not erase a real review.

# refute_provider <primary> — prefer a DIFFERENT provider that is ready, since a second
# model catches what the first one is blind to; otherwise the same one.
refute_provider() {
  local primary="$1" want other
  want="$(cfg_get '.refute.provider' '')"
  if [ -n "$want" ] && [ "$want" != "auto" ]; then printf '%s' "$want"; return 0; fi
  other="$(providers_probe_all 2>/dev/null | jq -r --arg p "$primary" \
    '[.[] | select(.name != $p and .available and .authed)] | .[0].name // empty' 2>/dev/null)"
  printf '%s' "${other:-$primary}"
}

# refute_prompt <norm.json> <diff_file> <pr_json> <checkout> <out>
refute_prompt() {
  local norm="$1" diff="$2" pr_json="$3" checkout="$4" out="$5"
  {
    cat "$SHARE_DIR/prompt/refute-role.md"
    printf '\n\n## The pull request\n\n- title: %s\n- base: `%s`\n\n' \
      "$(jq -r '.title // ""' "$pr_json")" "$(jq -r '.base // ""' "$pr_json")"
    printf '## Findings to check\n\n```json\n'
    jq '[.findings[] | {id, path, line, severity, title, body}]' "$norm"
    printf '```\n\n'
    if [ -n "$checkout" ]; then
      printf '## The code\n\nA checkout of this pull request is available read-only at `%s`.\n\n' "$checkout"
    else
      printf '## The code\n\nNo checkout is available; judge from the diff alone and say so in the reason.\n\n'
    fi
    printf '## The diff\n\n```diff\n'
    head -c 150000 "$diff"
    printf '\n```\n\n'
    printf '## Output contract\n\nReturn one JSON object and nothing else:\n\n'
    printf '```\n{"verdicts":[{"id":"<finding id>","verdict":"keep|drop|downgrade","severity":"convention|risk|nit (only with downgrade)","reason":"one sentence"}]}\n```\n'
  } > "$out"
}

# refute_apply <norm.json> <verdicts.json> — apply the verdicts in place; prints counts.
refute_apply() {
  local norm="$1" verdicts="$2"
  jq --slurpfile v "$verdicts" '
    def rank: {"blocker":0,"convention":1,"risk":2,"nit":3,"question":4}[.] // 9;
    ($v[0].verdicts // []) as $vs
    | (.findings | length) as $before
    | .findings |= [ .[] | . as $f
        | ($vs | map(select(.id == $f.id)) | .[0]) as $x
        | if $x == null then $f
          elif $x.verdict == "drop" and (($x.reason // "") | length) > 0 then empty
          elif $x.verdict == "downgrade" and ($x.severity != null)
               and (($x.severity | rank) > ($f.severity | rank)) and ($x.severity != "question")
            then $f + {severity: $x.severity, refutedFrom: $f.severity}
          else $f end ]
    | .refute = { checked: $before, kept: (.findings | length),
                  dropped: ($before - (.findings | length)),
                  downgraded: ([.findings[] | select(.refutedFrom)] | length) }' "$norm" > "$norm.t" \
    && mv "$norm.t" "$norm" \
    && jq -r '.refute | "kept \(.kept) of \(.checked), dropped \(.dropped), downgraded \(.downgraded)"' "$norm"
}

# refute_run <provider> <work> <checkout> <slug> <pr> — returns 0 whether or not the pass
# changed anything; non-zero only when it was skipped or failed (findings untouched).
refute_run() {
  local primary="$1" work="$2" checkout="$3" pr="$4"
  local prov pf raw out keep_cost keep_model keep_dur keep_tin keep_tout keep_turns cost2 rc

  jq -e '.findings | length > 0' "$work/norm.json" >/dev/null 2>&1 || return 1
  prov="$(refute_provider "$primary")"
  [ -n "$prov" ] || return 1

  pf="$work/refute-prompt.txt"; raw="$work/refute-raw"; out="$raw/verdicts.json"
  mkdir -p "$raw"
  refute_prompt "$work/norm.json" "$work/diff.txt" "$work/pr.json" "$checkout" "$pf"

  # The primary pass's numbers must survive: the provider adapters write them into
  # shared globals, and a second call would overwrite the review's own cost and model.
  keep_cost="${GOBLIN_P_COST_USD:-0}"; keep_model="${GOBLIN_P_MODEL:-}"; keep_dur="${GOBLIN_P_DURATION_MS:-0}"
  keep_tin="${GOBLIN_P_TOKENS_IN:-0}"; keep_tout="${GOBLIN_P_TOKENS_OUT:-0}"; keep_turns="${GOBLIN_P_TURNS:-0}"

  log "  #$pr: second look with $prov"
  local saved_schema="${SCHEMA_FILE:-}"
  SCHEMA_FILE="$SHARE_DIR/schema/refute.schema.json"
  findings_invoke "$prov" "$pf" "${checkout:-$work}" "$out" "$raw"; rc=$?
  SCHEMA_FILE="$saved_schema"
  cost2="${GOBLIN_P_COST_USD:-0}"

  GOBLIN_P_COST_USD="$(awk -v a="$keep_cost" -v b="$cost2" 'BEGIN{printf "%.6f", a+b}')"
  GOBLIN_P_MODEL="$keep_model"; GOBLIN_P_DURATION_MS="$keep_dur"
  GOBLIN_P_TOKENS_IN="$keep_tin"; GOBLIN_P_TOKENS_OUT="$keep_tout"; GOBLIN_P_TURNS="$keep_turns"

  if [ "$rc" -ne 0 ] || ! jq -e '(.verdicts | type) == "array"' "$out" >/dev/null 2>&1; then
    log "  #$pr: second look failed (${GOBLIN_P_ERRKIND:-other}) — keeping the findings as they were"
    return 1
  fi
  jq -r '.verdicts[] | select(.verdict != "keep") | "    \(.verdict) \(.id): \(.reason)"' "$out" 2>/dev/null \
    | while IFS= read -r line; do log "$line"; done
  log "  #$pr: second look — $(refute_apply "$work/norm.json" "$out")"
  return 0
}
