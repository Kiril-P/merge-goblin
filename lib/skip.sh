#!/usr/bin/env bash
# skip.sh — leave noisy pull requests alone BEFORE a model is paid to read them.
#
# Three rules, configured under `skip` (global) and `repos[].skip` (per repo, merged
# over the global object key by key, so a repo can set just `{"bots": false}`):
#
#   bots      true: skip PRs opened by a dependency bot (`botLogins`, matched without
#             the "[bot]" suffix or the "app/" prefix gh uses). A repo opts its bot PRs
#             back in with  repos[].skip.bots = false.
#   paths     skip when EVERY changed file matches one of these globs: lockfiles,
#             minified bundles, snapshots, generated code (see config.sh for the list).
#   docsOnly  true: also skip when every changed file is documentation (`docsPaths`) or
#             noise from `paths`. Off by default.
#
# The decision itself is share/jq/skip.jq (globs explained there). The bot rule needs
# only the author; the file rules cost one API call, made only when a file rule is on.
# A skip never touches GitHub: nothing is posted, nothing is claimed.

# skip_rules <slug> — the merged rules object for this repo.
skip_rules() {
  cfg_read | jq -c --arg s "$1" '
    (.skip // {}) * ([.repos[]? | select(.slug == $s) | (.skip // {})] | first // {})' 2>/dev/null \
    || printf '{}'
}

# skip_check <slug> <pr> <author> <files-out.json>
#   prints {reason, detail} and returns 0 when the PR should be skipped; 1 otherwise.
#   files-out is where the changed-file list is cached, if it had to be fetched.
skip_check() {
  local slug="$1" pr="$2" author="$3" files_out="$4" rules need_files verdict
  rules="$(skip_rules "$slug")"; [ -n "$rules" ] || rules='{}'
  echo '[]' > "$files_out"
  verdict="$(jq -nc --arg a "$author" --argjson rules "$rules" '{author:$a, files:[]}' \
             | jq -c --argjson rules "$rules" -f "$SHARE_DIR/jq/skip.jq" 2>/dev/null)"
  if [ "$(printf '%s' "$verdict" | jq -r '.skip' 2>/dev/null)" != "true" ]; then
    need_files="$(printf '%s' "$rules" | jq -r '((.paths // []) | length > 0) or (.docsOnly == true)' 2>/dev/null)"
    [ "$need_files" = "true" ] || return 1
    # Fails open: if the file list cannot be read, the review goes ahead.
    diff_fetch_files "$slug" "$pr" "$files_out" || return 1
    verdict="$(jq -c --arg a "$author" '{author:$a, files:[.[].filename]}' "$files_out" \
               | jq -c --argjson rules "$rules" -f "$SHARE_DIR/jq/skip.jq" 2>/dev/null)"
  fi
  [ "$(printf '%s' "$verdict" | jq -r '.skip' 2>/dev/null)" = "true" ] || return 1
  printf '%s' "$verdict" | jq -c '{reason, detail}'
}
