#!/usr/bin/env bash
# github.sh — all reads from GitHub. Writes live in post.sh, locking in claim.sh.

# gh_prs <slug> <out.json>
# One core-API call (5000/hr) instead of the search API (30/min), and it returns
# everything fleet assignment needs. Team review requests carry no `login` key,
# so entries are normalised to {kind,key} rather than assuming a user.
gh_prs() {
  local slug="$1" out="$2"
  gh pr list --repo "$slug" --state open --limit 100 \
    --json number,headRefOid,isDraft,title,url,baseRefName,author,reviewRequests,updatedAt,createdAt \
    2>/dev/null \
  | jq '[ .[] | {
      number, head: .headRefOid, draft: .isDraft, title, url,
      base: .baseRefName, author: (.author.login // ""),
      updatedAt: (.updatedAt | fromdateiso8601? // 0),
      createdAt: (.createdAt | fromdateiso8601? // 0),
      requested: [ .reviewRequests[]?
        | if .__typename == "Team"
          then {kind:"team", key: ((.organization.login // "") + "/" + (.slug // .name // ""))}
          else {kind:"user", key: (.login // "")} end
        | select(.key != "" and .key != "/") ]
    } ]' > "$out" 2>/dev/null
  jq -e 'type == "array"' "$out" >/dev/null 2>&1 || { echo '[]' > "$out"; return 1; }
}

# Expand a team slug to member logins, cached for a day (read:org scope needed).
gh_team_members() {
  local org_team="$1" cache="$GOBLIN_HOME/teams.json" org slug now
  org="${org_team%%/*}"; slug="${org_team##*/}"
  now="$(now_epoch)"
  if [ -f "$cache" ]; then
    local age members
    age="$(jq -r --arg k "$org_team" '.[$k].at // 0' "$cache" 2>/dev/null)"
    if [ "$(( now - ${age:-0} ))" -lt 86400 ]; then
      members="$(jq -r --arg k "$org_team" '.[$k].members[]?' "$cache" 2>/dev/null)"
      [ -n "$members" ] && { printf '%s\n' "$members"; return 0; }
    fi
  fi
  local list
  list="$(gh api --paginate "orgs/$org/teams/$slug/members?per_page=100" --jq '.[].login' 2>/dev/null)"
  [ -z "$list" ] && return 1
  local arr; arr="$(printf '%s\n' "$list" | jq -R . | jq -s .)"
  local cur='{}'; [ -f "$cache" ] && cur="$(cat "$cache" 2>/dev/null)"
  printf '%s' "$cur" | jq --arg k "$org_team" --argjson m "$arr" --argjson at "$now" \
    '.[$k] = {at:$at, members:$m}' > "$cache.tmp" 2>/dev/null && mv "$cache.tmp" "$cache"
  printf '%s\n' "$list"
}

# gh_pr_is_open <slug> <pr> — 0 if still open, 1 if merged/closed or unknown.
#
# `gh pr list` is a snapshot taken at the top of a run. A busy repo merges
# inside that window: PR #1441 merged at 12:32:27 and the review landed at
# 12:38:14, six minutes into a closed PR, where all three findings went unread.
# One cheap call before the model runs (and again before posting) is worth more
# than the review it prevents.
gh_pr_is_open() {
  local state
  state="$(gh api "repos/$1/pulls/$2" --jq '.state + (if .merged then "/merged" else "" end)' 2>/dev/null)"
  # An API blip must not silently suppress a legitimate review, so treat an
  # empty answer as "still open" and let the post itself fail if it is not.
  [ -z "$state" ] && return 0
  case "$state" in open) return 0 ;; *) return 1 ;; esac
}

# gh_pr_meta <slug> <pr> <out.json> — body + head sha for the prompt.
gh_pr_meta() {
  gh api "repos/$1/pulls/$2" \
    --jq '{number, title, body, base: .base.ref, head: .head.sha, author: .user.login, url: .html_url}' \
    > "$3" 2>/dev/null
}

# gh_marker_authors — a JSON array literal of the logins whose markers we trust: this
# account and the fleet. A marker is just text in a comment; anybody can paste one, and
# a forged "already reviewed" marker would make the PR silently un-reviewable.
gh_marker_authors() {
  local list="${GOBLIN_LOGIN:-}"
  list="$list $(cfg_get_json '.fleet // []' '[]' | jq -r '.[]?' 2>/dev/null)"
  printf '%s' "$list" | tr -c 'A-Za-z0-9-' '\n' | grep . | sort -u | jq -R . | jq -sc .
}

# gh_prior_review <slug> <pr> — the most recent review marker on this PR, or empty.
# Read from GitHub (not local state) so a fresh machine still knows what was posted.
# Matches the pre-rename prefix too, else a rename would make the Goblin forget
# every review it had already posted and duplicate all of them.
gh_prior_review() {
  local who all; who="$(gh_marker_authors)"; [ -n "$who" ] || who='[]'
  # One answer for the whole PR, not one per page of reviews (see gh_api_all).
  all="$(gh_api_all "repos/$1/pulls/$2/reviews?per_page=100")" || return 0
  printf '%s' "$all" | jq -c '
    '"$who"' as $who
    | [ .[]
      | select(.body != null and ((.user.login // "") as $u | $who | index($u)))
      | (.body | capture("<!-- (?<ns>'"$GOBLIN_MARKER_NS"'|'"$GOBLIN_MARKER_NS_LEGACY"'):review (?<j>\\{.*?\\}) -->") // empty) as $c
      | (try ($c.j | fromjson) catch empty) as $m
      | { submitted_at, commit_id, m: $m } ]
    | sort_by(.submitted_at) | last // empty' 2>/dev/null
}

# gh_reviews_fetch <slug> <pr> <dest> — the raw reviews array, to a file.
#
# A file rather than a pipe because two callers want two different questions
# answered from the same page of results (has a human reviewed this, and what did
# the Goblin last say), and paying for the round trip twice per PR per poll adds up
# fast on a repo with twenty open PRs. Fails if the response is not an array, so a
# rate-limit error object can never be read as "no reviews".
gh_reviews_fetch() {
  gh_api_all "repos/$1/pulls/$2/reviews?per_page=100" > "$3" || return 1
  jq -e 'type == "array"' "$3" >/dev/null 2>&1 || return 1
}

# gh_human_reviewers <reviews-file> — logins of real people who have reviewed.
#
# Three exclusions, each one a wrong answer we have seen:
#   * PENDING reviews are drafts only their author can see
#   * bots, by user.type and by the "[bot]" suffix, because a review from another
#     automation is not a human having looked at this
#   * the Goblin's OWN reviews, which are posted under a human token and so are
#     indistinguishable from that human's reviews except by the hidden marker.
#     Without this the Goblin sees its own review, concludes a human is on it, and
#     never reviews that repo again.
gh_human_reviewers() {
  jq -r --arg me "${GOBLIN_LOGIN:-}" \
        --arg ns "$GOBLIN_MARKER_NS" '
    [ .[]
      | select((.state // "") != "PENDING")
      | select(((.user.type // "") | ascii_downcase) != "bot")
      | select(((.user.login // "") | test("\\[bot\\]$")) | not)
      | select(
          ((.user.login // "") | ascii_downcase) != ($me | ascii_downcase)
          or ((.body // "") | test("<!-- " + $ns + ":review ") | not)
        )
      | .user.login ]
    | unique | .[]' "$1" 2>/dev/null
}

# gh_prior_findings <slug> <pr> — the findings already posted inline, for dedupe, each
# with `declined` saying whether the PR's people pushed back on it.
#
# Output: [{id, severity, …marker fields, commentId, path, line, title,
#           declined, declinedBy, declinedHow}]
#
# `.line` can be null on outdated comments (only the deprecated `position` survives),
# so it falls back to original_line. The decline heuristic lives in
# share/jq/prior-findings.jq. Resolved threads come from GraphQL (REST does not say),
# and that call is only made when there is at least one finding of ours to ask about;
# if it fails, replies alone decide.
gh_prior_findings() {
  local slug="$1" pr="$2" who all resolved='[]'
  who="$(gh_marker_authors)"; [ -n "$who" ] || who='[]'
  all="$(gh_api_all "repos/$slug/pulls/$pr/comments?per_page=100")" || return 1
  if printf '%s' "$all" | jq -e --arg a "<!-- $GOBLIN_MARKER_NS:finding " --arg b "<!-- $GOBLIN_MARKER_NS_LEGACY:finding " \
       'any(.[]; (.body // "") | (contains($a) or contains($b)))' >/dev/null 2>&1; then
    resolved="$(gh_resolved_thread_roots "$slug" "$pr")" || resolved='[]'
    [ -n "$resolved" ] || resolved='[]'
  fi
  printf '%s' "$all" | jq -c --argjson who "$who" --arg ns "$GOBLIN_MARKER_NS" \
    --arg legacy "$GOBLIN_MARKER_NS_LEGACY" --argjson resolved "$resolved" \
    -f "$SHARE_DIR/jq/prior-findings.jq" 2>/dev/null
}

# gh_resolved_thread_roots <slug> <pr> -> JSON array of the REST ids of the FIRST comment
# of every resolved review thread. Paginated (threads come 100 at a time).
GH_RESOLVED_QUERY='query($owner:String!,$name:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{isResolved comments(first:1){nodes{databaseId}}}}}}}'
gh_resolved_thread_roots() {
  local raw
  raw="$(gh api graphql --paginate -f query="$GH_RESOLVED_QUERY" \
          -f owner="${1%%/*}" -f name="${1#*/}" -F number="$2" 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | jq -cs '
    if all(.[]; (.data.repository.pullRequest.reviewThreads.nodes | type) == "array")
    then [ .[] | .data.repository.pullRequest.reviewThreads.nodes[]
           | select(.isResolved == true) | (.comments.nodes[0].databaseId // empty) ]
    else error("bad page") end' 2>/dev/null
}

# gh_find_comment <slug> <pr> <marker-type> — id of an existing comment, for upsert.
gh_find_comment() {
  gh_api_all "repos/$1/issues/$2/comments?per_page=100" \
  | jq -r --arg a "$GOBLIN_MARKER_NS:$3" --arg b "$GOBLIN_MARKER_NS_LEGACY:$3" \
      '[.[] | select(.body != null and ((.body | contains($a)) or (.body | contains($b)))) | .id] | first // empty' 2>/dev/null
}

# gh_ticket_context <slug> <pr> <pr.json> <out>
# Pull the linked issue's text so the intent check reviews against what was
# actually asked. No Linear API needed: the PR body carries the link, and the
# Linear GitHub app posts a linkback comment that embeds the full description.
gh_ticket_context() {
  local slug="$1" pr="$2" prjson="$3" out="$4"
  : > "$out"
  local body key url
  body="$(jq -r '.body // ""' "$prjson" 2>/dev/null)"
  url="$(printf '%s' "$body" | grep -oE 'https://linear\.app/[^) ]+' | head -1)"
  # The key comes from the tracker link when there is one. A bare WORD-123 in prose is
  # as likely to be UTF-8, SHA-256 or CVE-2024 as a ticket, so those are never keys,
  # and `ticketKeyPrefixes` in the config narrows it to the prefixes a team really uses.
  key="$(printf '%s' "$url" | grep -oE '/issue/[A-Z][A-Z0-9]+-[0-9]+' | head -1 | sed 's#/issue/##')"
  if [ -z "$key" ]; then
    local prefixes; prefixes="$(cfg_get_json '.ticketKeyPrefixes // []' '[]' | jq -r 'join("|")' 2>/dev/null)"
    if [ -n "$prefixes" ]; then
      key="$(printf '%s' "$body" | grep -oE "\\b($prefixes)-[0-9]+" | head -1)"
    else
      key="$(printf '%s' "$body" | grep -oE '\b[A-Z][A-Z0-9]+-[0-9]+' \
             | grep -vE '^(UTF|SHA|ISO|CVE|CWE|RFC|MD|AES|RSA|TLS|SSL|HTTP|IPV|WCAG|OAUTH|GPT|PR|ES|PEP|BIP|X|CRC|BASE|ECMA)-' | head -1)"
    fi
  fi

  local linkback
  linkback="$(gh_api_all "repos/$slug/issues/$pr/comments?per_page=100" \
    | jq -r '[.[] | select(.body != null and (.user.type == "Bot") and ((.user.login // "") | test("linear"; "i"))
                        and (.body | test("linear-linkback|linear\\.app")))
           | .body] | first // empty' 2>/dev/null)"

  if [ -n "$key" ] || [ -n "$linkback" ]; then
    { [ -n "$key" ] && printf 'Issue: %s\n' "$key"
      [ -n "$url" ] && printf 'Link: %s\n' "$url"
      if [ -n "$linkback" ]; then
        printf '\nIssue description (from the tracker):\n\n'
        printf '%s\n' "$linkback" | sed 's/<[^>]*>//g' | head -c 6000
      fi
    } > "$out"
  fi
  printf '%s' "$key"
}

# gh_status <slug> <sha> <state> <desc> [url] — SHA-scoped visible marker.
gh_status() {
  [ "$(cfg_get '.postCommitStatus' true)" = "true" ] || return 0
  # a private review of your own PR leaves nothing on GitHub, not even a check
  [ "${ENGINE_MINE:-}" = hold ] && return 0
  local slug="$1" sha="$2" state="$3" desc="$4" url="${5:-}"
  # GitHub refuses any 4-byte character in a status description (422), and the
  # counts start with 🔴/🟡: every "posted" status was rejected, leaving the check
  # pending forever. Drop the emoji (and the BMP symbol/variation-selector ones that
  # would now look orphaned), keep the words.
  desc="$(printf '%s' "$desc" | jq -Rr 'explode
      | map(select(. < 65536 and (. < 9728 or . > 10175) and . != 65039))
      | implode | gsub(" {2,}"; " ") | ltrimstr(" ")' 2>/dev/null || printf '%s' "$desc")"
  set -- -f state="$state" -f context="$GOBLIN_SLUG/review" -f description="$(trunc "$desc" 138)"
  [ -n "$url" ] && set -- "$@" -f target_url="$url"
  gh api -X POST "repos/$slug/statuses/$sha" "$@" --silent >/dev/null 2>&1 || true
}

# gh_other_comments <slug> <pr> -> one line per comment someone ELSE left on the pull
# request: inline review comments and review summaries, without our own markers and
# without ours at all. Fed to the model as "already raised", so it does not repeat what
# a human or another bot already said. Failures yield nothing: this is only context.
# Pagination-safe as it stands: --jq emits one object PER COMMENT (never a per-page
# aggregate) and the closing `jq -s` collects them across every page.
gh_other_comments() {
  local slug="$1" pr="$2" me="${GOBLIN_LOGIN:-}"
  {
    gh api --paginate "repos/$slug/pulls/$pr/comments?per_page=100" --jq '.[]
      | select(.body != null and (.body | test("<!-- ('"$GOBLIN_MARKER_NS"'|'"$GOBLIN_MARKER_NS_LEGACY"'):"; "i") | not))
      | {user: .user.login, path: .path, line: (.line // .original_line), body: .body}' 2>/dev/null
    gh api --paginate "repos/$slug/pulls/$pr/reviews?per_page=100" --jq '.[]
      | select((.body // "") != "" and (.body | test("<!-- ('"$GOBLIN_MARKER_NS"'|'"$GOBLIN_MARKER_NS_LEGACY"'):"; "i") | not))
      | {user: .user.login, path: null, line: null, body: .body}' 2>/dev/null
  } | jq -rs --arg me "$me" '
      map(select(.user != $me))
      | .[0:40][]
      | "- " + (if .path then "\(.path):\(.line // "?") " else "(review) " end)
        + "@\(.user): " + (.body | gsub("\\s+"; " ") | .[0:240])' 2>/dev/null
}
