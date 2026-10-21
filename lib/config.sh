#!/usr/bin/env bash
# config.sh — the config plane. Ported from prauto-lib.sh, same function names.

GOBLIN_CONFIG_SCHEMA_VERSION=2

# Defaults are also the migration target: cfg_backfill adds any missing key
# without ever overwriting a user's value.
goblin_default_config() {
  cat <<JSON
{
  "schemaVersion": $GOBLIN_CONFIG_SCHEMA_VERSION,
  "identity": { "githubLogin": "" },
  "enabled": true,
  "snoozeUntil": 0,
  "intervalSeconds": 300,
  "provider": "claude",
  "providers": {
    "claude": { "model": "sonnet", "bin": "" },
    "codex":  { "model": "", "reasoningEffort": "medium", "bin": "" },
    "cursor": { "model": "", "bin": "" }
  },
  "providerFallback": [],
  "timeoutSecs": 900,
  "repos": [],
  "fleet": [],
  "fleetAssignment": true,
  "takeoverGraceSecs": 2700,
  "claimTtlSecs": 3600,
  "verdictMode": "comment",
  "allowApprove": false,
  "budgetCapUsd": 10,
  "maxReviewsPerRun": 5,
  "maxFindings": 25,
  "refutePass": true,
  "autoPost": "always",
  "reviewMine": "off",
  "reviewMineDrafts": false,
  "gitTimeoutSecs": 120,
  "maxDiffBytes": 400000,
  "postIntentComment": true,
  "postCommitStatus": true,
  "incrementalReview": true,
  "notify": { "started": true, "posted": true, "failed": true, "budget": true, "sound": true },
  "refsForbidden": false,
  "refsForbiddenAt": 0,
  "update": { "notify": true, "checkEverySecs": 86400 },
  "maxReviewsPerDay": 20,
  "skipIfHumanReviewed": true,
  "skip": {
    "bots": true,
    "botLogins": ["dependabot", "dependabot-preview", "renovate", "renovate-bot", "snyk-bot", "depfu", "greenkeeper", "pyup-bot"],
    "docsOnly": false,
    "docsPaths": ["*.md", "*.mdx", "*.markdown", "*.rst", "docs/**"],
    "paths": [
      "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb",
      "Podfile.lock", "Gemfile.lock", "go.sum", "Cargo.lock", "composer.lock", "poetry.lock",
      "Pipfile.lock", "uv.lock", "mix.lock", "pubspec.lock", "Package.resolved", "flake.lock",
      "*.min.js", "*.min.css", "*.js.map", "*.css.map",
      "**/__snapshots__/**", "*.snap",
      "**/__generated__/**", "*.generated.*", "*.pb.go", "*_pb2.py", "*_pb2_grpc.py",
      "**/dist/**", "**/node_modules/**", "vendor/**"
    ]
  },
  "manualReviewMode": "preview",
  "maxConcurrentJobs": 2,
  "lastRepo": "",
  "setupComplete": false,
  "cache": { "reposTtlSecs": 3600 }
}
JSON
}

# GOBLIN_CFG_OVERLAY is a JSON object merged over the file for THIS process only — how
# a manual review runs with a different provider or model without touching the
# config every other process reads. Writers (cfg_set) deliberately ignore it, so an
# overlay can never be persisted by accident.
cfg_read() {
  if [ -n "${GOBLIN_CFG_OVERLAY:-}" ]; then
    jq -c --argjson o "$GOBLIN_CFG_OVERLAY" '. * $o' "$CONFIG" 2>/dev/null
  else
    cat "$CONFIG" 2>/dev/null
  fi
}
cfg_read_file() { cat "$CONFIG" 2>/dev/null; }

cfg_ensure() {
  goblin_ensure_dirs
  if ! cfg_read | jq -e . >/dev/null 2>&1; then
    goblin_default_config > "$CONFIG"
  fi
}

# cfg_get <jq-filter> <default>
cfg_get() {
  local filter="$1" default="${2:-}" v
  v="$(cfg_read | jq -r "$filter" 2>/dev/null)"
  if [ -z "$v" ] || [ "$v" = "null" ]; then printf '%s' "$default"; else printf '%s' "$v"; fi
}

# cfg_get_json <jq-filter> <default-json> — for arrays/objects.
cfg_get_json() {
  local filter="$1" default="${2:-null}" v
  v="$(cfg_read | jq -c "$filter" 2>/dev/null)"
  if [ -z "$v" ] || [ "$v" = "null" ]; then printf '%s' "$default"; else printf '%s' "$v"; fi
}

# cfg_set [jq-args...] <jq-assignment> — atomic read-modify-write.
# Extra jq options (--arg/--argjson) may precede the filter.
cfg_set() {
  cfg_ensure
  local out
  if out="$(cfg_read_file | jq "$@" 2>/dev/null)" && [ -n "$out" ]; then
    printf '%s\n' "$out" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  else
    rm -f "$CONFIG.tmp" 2>/dev/null
    return 1
  fi
}

# Add keys introduced by a newer version without clobbering existing values.
# `*` in jq is a recursive merge where the RIGHT side wins, so defaults go left.
cfg_backfill_defaults() {
  cfg_ensure
  local merged
  merged="$(jq -s '.[0] * .[1] | .schemaVersion = '"$GOBLIN_CONFIG_SCHEMA_VERSION" \
    <(goblin_default_config) "$CONFIG" 2>/dev/null)"
  [ -n "$merged" ] && printf '%s\n' "$merged" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
}

# --- repos ----------------------------------------------------------------
# Each entry: {slug, enabled, promptPath, login, provider?, model?, skip?}
#   provider/model  who reviews THIS repo (cfg_repo_provider); empty = the global one
#   skip            a partial `skip` object merged over the global one (lib/skip.sh)
cfg_repos_enabled() {
  cfg_read | jq -r '.repos[]? | select(.enabled != false) | .slug' 2>/dev/null
}

cfg_repo_field() {  # <slug> <field> <default>
  local slug="$1" field="$2" def="${3:-}" v
  v="$(cfg_read | jq -r --arg s "$slug" --arg f "$field" \
        '.repos[]? | select(.slug == $s) | .[$f] // empty' 2>/dev/null | head -1)"
  [ -z "$v" ] && v="$def"
  printf '%s' "$v"
}

cfg_repo_add() {  # <slug>
  cfg_ensure
  cfg_set --arg s "$1" \
    'if ([.repos[]?.slug] | index($s)) then . else .repos += [{slug:$s, enabled:true, promptPath:"", login:""}] end'
}

# cfg_repo_set_field <slug> <field> <value> — the setter half of cfg_repo_field.
#
# The value is run through jq -R so "5" stores as a number and "true" as a boolean
# rather than as strings: the panel sends everything as text, and a string where a
# boolean belongs reads as truthy forever afterwards.
cfg_repo_set_field() {
  local slug="$1" field="$2" raw="$3" val
  val="$(printf '%s' "$raw" | jq -R 'tonumber? // (if . == "true" then true elif . == "false" then false else . end)')"
  cfg_set --arg s "$slug" --arg f "$field" --argjson v "$val" \
    '.repos |= map(if .slug == $s then .[$f] = $v else . end)'
}

# cfg_repo_set_provider <slug> <provider|default> [model]
#   who reviews this repo. `default` (or empty) removes both fields, so the repo follows
#   the global provider again. The model is only kept together with a provider.
#   Returns 2 on a value it refuses, 1 when the repo is not watched.
cfg_repo_set_provider() {
  local slug="$1" prov="${2:-}" model="${3:-}"
  printf '%s' "$slug" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9._-]{1,100}$' || return 2
  cfg_read | jq -e --arg s "$slug" 'any(.repos[]?; .slug == $s)' >/dev/null 2>&1 || return 1
  case "$prov" in
    ""|default)
      cfg_set --arg s "$slug" '.repos |= map(if .slug == $s then del(.provider, .model) else . end)' ;;
    claude|codex|cursor)
      # starts with a letter or digit: a model name is handed to the provider's CLI as
      # the value of --model, and must never be able to look like a flag itself
      if [ -n "$model" ]; then
        printf '%s' "$model" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$' || return 2
      fi
      cfg_set --arg s "$slug" --arg p "$prov" --arg m "$model" \
        '.repos |= map(if .slug == $s then (.provider = $p | if $m == "" then del(.model) else .model = $m end) else . end)' ;;
    *) return 2 ;;
  esac
}

cfg_repo_rm()     { cfg_set --arg s "$1" '.repos |= map(select(.slug != $s))'; }
cfg_repo_enable() { cfg_set --arg s "$1" --argjson e "$2" '.repos |= map(if .slug == $s then .enabled = $e else . end)'; }

# The GitHub login the Goblin reviews as. Config first, then the active gh account.
goblin_login() {
  local l; l="$(cfg_get '.identity.githubLogin' '')"
  if [ -z "$l" ]; then l="$(gh api user --jq .login 2>/dev/null)"; fi
  printf '%s' "$l"
}
