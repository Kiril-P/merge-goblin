#!/usr/bin/env bash
# claude.sh — Anthropic Claude Code CLI adapter.
#
# The only provider that reports real dollar cost, and it enforces our schema
# natively via --json-schema, so output is structured rather than scraped.

provider_claude_bin() {
  local b; b="$(cfg_get '.providers.claude.bin' '')"
  [ -n "$b" ] && [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  b="$(command -v claude 2>/dev/null)"
  [ -n "$b" ] && { printf '%s' "$b"; return 0; }
  # Known install locations — a moved binary broke this once already.
  for b in "$HOME/.local/bin/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude" \
           "$HOME/Library/Application Support/com.conductor.app/bin/claude"; do
    [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done
  return 1
}

provider_claude_probe() {
  local bin ver auth logged method
  bin="$(provider_claude_bin || true)"
  if [ -z "$bin" ]; then
    jq -nc '{name:"claude",available:false,authed:false,note:"claude CLI not found"}'; return 0
  fi
  ver="$("$bin" --version 2>/dev/null | head -1)"
  auth="$("$bin" auth status 2>/dev/null)"
  logged="$(printf '%s' "$auth" | jq -r '.loggedIn // false' 2>/dev/null)"
  method="$(printf '%s' "$auth" | jq -r '(.subscriptionType // .authMethod) // ""' 2>/dev/null)"
  jq -nc --arg bin "$bin" --arg ver "$ver" --arg m "$method" --argjson logged "${logged:-false}" \
    '{name:"claude", available:true, authed:$logged, authMode:$m, version:$ver,
      costKnown:true, schemaMode:"native", bin:$bin, note:""}'
}

# provider_claude_review <prompt_file> <repo_dir> <schema> <out_json> <raw_dir>
provider_claude_review() {
  local pf="$1" dir="$2" schema="$3" out="$4" raw="$5"
  local bin model to t0 rc=0
  bin="$(provider_claude_bin)" || { GOBLIN_P_ERRKIND=other; GOBLIN_P_ERRMSG="claude not found"; return 1; }
  model="$(cfg_get '.providers.claude.model' 'sonnet')"
  to="$(cfg_get '.timeoutSecs' 900)"
  t0="$(now_epoch)"

  # What the model may touch. With a checkout of the pull request it gets Read, Grep and
  # Glob and nothing else — no Bash, no Write, no network — so it can check a claim
  # against the real code instead of guessing from the diff. Without one it gets no tools.
  #
  # The checkout is the PR author's: it can hold a .claude/settings.json (hooks), a
  # .mcp.json and a CLAUDE.md, all of which `claude -p` would obey if it ran in there.
  # So it runs in an empty directory with the checkout added as readable, and only the
  # user's own settings are loaded. dontAsk turns every other permission request into a
  # refusal instead of a prompt nobody can answer. No bypassPermissions anywhere.
  #
  # The prompt goes in on STDIN, not as a positional arg: --tools is variadic and
  # would otherwise swallow the prompt as a tool name ("Input must be provided
  # either through stdin or as a prompt argument"). Redirecting from the prompt
  # file also keeps `claude -p`'s stdin drain away from the engine's PR loop.
  #
  # Allowing plain `Read` is NOT confinement: tested, it happily reads /etc/hosts and
  # ~/.zshrc from a session whose directory is somewhere else. Each tool is therefore
  # allowed only for paths under the checkout, and everything else is denied by dontAsk.
  # A path containing a space cannot be written into the comma/space-separated list, so
  # such a checkout is treated as not readable rather than risking a wider rule.
  local cwd="$raw/cwd"; mkdir -p "$cwd"
  local scope="/$dir/**"
  case "$dir" in *[[:space:],\(\)]*) scope="" ;; esac
  if [ -d "$dir/.git" ] && [ -n "$scope" ]; then
    ( cd "$cwd" || exit 1
      run_with_timeout "$to" "$bin" -p \
        --model "$model" \
        --output-format json \
        --json-schema "$(cat "$schema")" \
        --tools "Read,Grep,Glob" \
        --allowedTools "Read($scope)" "Grep($scope)" "Glob($scope)" \
        --permission-mode dontAsk \
        --add-dir "$dir" \
        --setting-sources user \
        --strict-mcp-config \
        > "$raw/stdout.json" 2> "$raw/stderr.txt" < "$pf"
    ) || rc=$?
  else
    ( cd "$cwd" || exit 1
      run_with_timeout "$to" "$bin" -p \
        --model "$model" \
        --output-format json \
        --json-schema "$(cat "$schema")" \
        --tools "" \
        --setting-sources user \
        --strict-mcp-config \
        > "$raw/stdout.json" 2> "$raw/stderr.txt" < "$pf"
    ) || rc=$?
  fi

  GOBLIN_P_DURATION_MS=$(( ($(now_epoch) - t0) * 1000 ))
  GOBLIN_P_MODEL="$model"
  GOBLIN_P_COST_KNOWN=true
  GOBLIN_P_COST_USD="$(jq -r '.total_cost_usd // 0' "$raw/stdout.json" 2>/dev/null)"
  [ -z "$GOBLIN_P_COST_USD" ] || [ "$GOBLIN_P_COST_USD" = "null" ] && GOBLIN_P_COST_USD=0
  GOBLIN_P_TOKENS_IN="$(jq -r '.usage.input_tokens // 0'  "$raw/stdout.json" 2>/dev/null)"
  GOBLIN_P_TOKENS_OUT="$(jq -r '.usage.output_tokens // 0' "$raw/stdout.json" 2>/dev/null)"
  GOBLIN_P_TURNS="$(jq -r '.num_turns // 0' "$raw/stdout.json" 2>/dev/null)"

  if [ "$rc" = "124" ]; then
    GOBLIN_P_ERRKIND=timeout; GOBLIN_P_ERRMSG="timed out after ${to}s"; return 124
  fi
  if [ "$rc" != "0" ]; then
    GOBLIN_P_ERRKIND="$(provider_classify_error "$(provider_error_text "$raw")")"
    GOBLIN_P_ERRMSG="$(provider_error_line "$raw")"
    return 1
  fi
  if [ "$(jq -r '.is_error // false' "$raw/stdout.json" 2>/dev/null)" = "true" ]; then
    GOBLIN_P_ERRMSG="$(jq -r '.result // "model reported an error"' "$raw/stdout.json" 2>/dev/null | head -c 300)"
    # A usage limit arrives here, as a result with is_error set and a clean exit.
    GOBLIN_P_ERRKIND="$(provider_classify_error "$GOBLIN_P_ERRMSG")"
    return 1
  fi

  # --json-schema gives a parsed object; fall back to the raw text if absent.
  if jq -e '.structured_output | type == "object"' "$raw/stdout.json" >/dev/null 2>&1; then
    jq '.structured_output' "$raw/stdout.json" > "$out"
    return 0
  fi
  jq -r '.result // ""' "$raw/stdout.json" > "$raw/last.txt" 2>/dev/null
  findings_extract "$raw/last.txt" "$out" && return 0
  GOBLIN_P_ERRKIND=bad_output; GOBLIN_P_ERRMSG="no JSON in response"
  return 2
}

# The models `claude --model` accepts. Aliases follow the latest release of each
# family; the pinned ids are for people who want a review to stay on one version.
provider_claude_models() {
  jq -nc '[
    {id:"sonnet", label:"Sonnet (latest)"},
    {id:"opus",   label:"Opus (latest)"},
    {id:"haiku",  label:"Haiku (latest)"},
    {id:"claude-sonnet-5-5", label:"Sonnet 5.5"},
    {id:"claude-opus-5-5",   label:"Opus 5.5"},
    {id:"claude-haiku-5-5",  label:"Haiku 5.5"},
    {id:"claude-fable-5-1",  label:"Fable 5.1"}
  ]'
}
