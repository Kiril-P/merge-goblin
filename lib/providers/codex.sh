#!/usr/bin/env bash
# codex.sh — OpenAI Codex CLI adapter (ChatGPT subscription auth).
#
# Enforces our schema natively via --output-schema. Subscription auth means no
# dollar figure is reported; the engine falls back to counting reviews.

provider_codex_bin() {
  local b; b="$(cfg_get '.providers.codex.bin' '')"
  [ -n "$b" ] && [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  b="$(command -v codex 2>/dev/null)"
  [ -n "$b" ] && { printf '%s' "$b"; return 0; }
  for b in "/opt/homebrew/bin/codex" "/usr/local/bin/codex" "$HOME/.local/bin/codex"; do
    [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done
  return 1
}

provider_codex_probe() {
  local bin ver authed=false mode="" model
  bin="$(provider_codex_bin || true)"
  if [ -z "$bin" ]; then
    jq -nc '{name:"codex",available:false,authed:false,note:"codex CLI not found"}'; return 0
  fi
  ver="$("$bin" --version 2>/dev/null | head -1)"
  # auth.json is written by `codex login`; auth_mode distinguishes ChatGPT
  # subscription from an API key.
  if [ -f "$HOME/.codex/auth.json" ]; then
    mode="$(jq -r '.auth_mode // ""' "$HOME/.codex/auth.json" 2>/dev/null)"
    if jq -e '(.tokens != null) or (.OPENAI_API_KEY != null and .OPENAI_API_KEY != "")' \
         "$HOME/.codex/auth.json" >/dev/null 2>&1; then authed=true; fi
  fi
  model="$(cfg_get '.providers.codex.model' '')"
  [ -z "$model" ] && model="$(grep -E '^model *=' "$HOME/.codex/config.toml" 2>/dev/null | head -1 | sed 's/.*= *//; s/"//g')"
  jq -nc --arg bin "$bin" --arg ver "$ver" --arg m "${mode:-unknown}" --arg model "$model" \
     --argjson authed "$authed" \
    '{name:"codex", available:true, authed:$authed, authMode:$m, version:$ver, model:$model,
      costKnown:false, schemaMode:"native-file", bin:$bin,
      note:(if $authed then "" else "run: codex login" end)}'
}

provider_codex_review() {
  local pf="$1" dir="$2" schema="$3" out="$4" raw="$5"
  local bin model eff to t0 rc=0
  bin="$(provider_codex_bin)" || { GOBLIN_P_ERRKIND=other; GOBLIN_P_ERRMSG="codex not found"; return 1; }
  model="$(cfg_get '.providers.codex.model' '')"
  eff="$(cfg_get '.providers.codex.reasoningEffort' 'medium')"
  to="$(cfg_get '.timeoutSecs' 900)"
  t0="$(now_epoch)"

  # OpenAI's structured-output dialect is stricter than JSON Schema: every
  # property must be listed in `required` (optional fields become nullable
  # unions), else the API rejects the request with invalid_json_schema.
  local strict="${schema%.schema.json}.strict.schema.json"
  [ -f "$strict" ] && schema="$strict"

  # WHAT THE MODEL CAN READ. Codex reads files by running shell commands, and every
  # one runs inside codex's macOS sandbox (Seatbelt). `--sandbox read-only` stops writes
  # and network but lets those commands read the WHOLE disk — tested: `ls ~/.ssh` and
  # any file under $HOME came straight back. So, where this codex supports permission
  # profiles, it gets one (provider_codex_profile) that can read:
  #   * the PR checkout, and nothing else of yours — not $HOME, not ~/.goblin, not the
  #     other clones, not /tmp or $TMPDIR
  #   * codex's `:minimal` set: the system files a shell needs to start (/bin, /usr,
  #     /System, /etc, …), which hold nothing of yours
  # with no writes anywhere and no network. Verified against codex-cli 0.163 with a real
  # `codex exec`: the checkout read fine; a file under $HOME, ~/.ssh, /tmp, a write and
  # `curl` were all refused (the README records the exact test).
  #
  # It runs from an EMPTY directory, not the checkout: the checkout is the PR author's,
  # and codex would otherwise load its AGENTS.md as instructions (project_doc_max_bytes=0
  # turns that off too, belt and braces) and walk it for project config.
  #
  # Older codex builds have no profiles. provider_codex_can_confine finds out by asking
  # the sandbox to read one file inside and one outside a scratch grant; if it cannot,
  # the review falls back to `--sandbox read-only` and the log says reads are NOT
  # confined. Not confined is never silent.
  local cwd="$raw/cwd" readable=""; mkdir -p "$cwd"
  [ -d "$dir/.git" ] && readable="$dir"
  set -- exec --cd "$cwd" --skip-git-repo-check \
        --output-schema "$schema" --output-last-message "$raw/last.txt" --json
  if provider_codex_can_confine "$bin" "$raw"; then
    set -- "$@" -c 'default_permissions="goblin"' -c "$(provider_codex_profile "$readable")"
    GOBLIN_P_CONFINED=true
  else
    set -- "$@" --sandbox read-only
    GOBLIN_P_CONFINED=false
    log "  codex: this codex has no permission profiles, so its reads are NOT confined to the checkout (--sandbox read-only can read the whole disk). Update codex to fix."
  fi
  set -- "$@" -c 'project_doc_max_bytes=0'
  [ -n "$model" ] && set -- "$@" --model "$model"
  [ -n "$eff" ]   && set -- "$@" -c "model_reasoning_effort=\"$eff\""
  # The user's own config.toml can load plugins, MCP servers and hooks that are
  # slow or interactive — unsuitable under launchd. --ignore-user-config drops
  # those, but it ALSO drops cli_auth_credentials_store="file", which would send
  # codex to the keychain (unreachable from a background agent), so put it back.
  set -- "$@" --ignore-user-config -c 'cli_auth_credentials_store="file"'

  # `codex exec -` reads the prompt from stdin, which avoids both argv length
  # limits on large diffs and any flag/positional ambiguity.
  ( cd "$cwd" || exit 1
    run_with_timeout "$to" "$bin" "$@" - \
      > "$raw/stdout.jsonl" 2> "$raw/stderr.txt" < "$pf" ) || rc=$?

  GOBLIN_P_DURATION_MS=$(( ($(now_epoch) - t0) * 1000 ))
  GOBLIN_P_MODEL="${model:-codex-default}"
  GOBLIN_P_COST_KNOWN=false
  GOBLIN_P_COST_USD=0
  # Token usage does come through the event stream even though cost doesn't.
  GOBLIN_P_TOKENS_IN="$(jq -rs '[.[]? | .. | objects | .input_tokens? // empty] | last // 0' "$raw/stdout.jsonl" 2>/dev/null)"
  GOBLIN_P_TOKENS_OUT="$(jq -rs '[.[]? | .. | objects | .output_tokens? // empty] | last // 0' "$raw/stdout.jsonl" 2>/dev/null)"
  GOBLIN_P_TURNS=0

  if [ "$rc" = "124" ]; then GOBLIN_P_ERRKIND=timeout; GOBLIN_P_ERRMSG="timed out after ${to}s"; return 124; fi
  if [ "$rc" != "0" ]; then
    GOBLIN_P_ERRKIND="$(provider_classify_error "$(cat "$raw/stderr.txt" 2>/dev/null)")"
    GOBLIN_P_ERRMSG="$(head -c 300 "$raw/stderr.txt" 2>/dev/null)"
    return 1
  fi

  findings_extract "$raw/last.txt" "$out" && return 0
  GOBLIN_P_ERRKIND=bad_output; GOBLIN_P_ERRMSG="no JSON in final message"
  return 2
}

# _codex_toml_str <s> — a TOML basic string ("…" with \ and " escaped). Fails on control
# characters, which no path we hand codex should contain.
_codex_toml_str() {
  case "$1" in *[[:cntrl:]]*) return 1 ;; esac
  printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# provider_codex_profile [readable-dir] — the `-c` override defining the "goblin"
# permission profile: codex's minimal system set readable, the temp dirs explicitly
# denied (`:minimal` lets /tmp through otherwise), the one directory readable, and no
# write or network grant at all. A more specific path beats a broader one, so a checkout
# that happens to live under a temp dir is still readable.
provider_codex_profile() {
  local p='permissions.goblin.filesystem={":minimal"="read", ":tmpdir"="none", "/tmp"="none", "/private/tmp"="none"' q
  if [ -n "${1:-}" ] && q="$(_codex_toml_str "$1")"; then p="$p, $q=\"read\""; fi
  printf '%s}' "$p"
}

# provider_codex_can_confine <bin> <scratch-dir> — 0 when this codex's sandbox, given the
# profile above, reads inside the grant AND refuses outside it. Both halves matter: a
# codex that ignores the unknown keys would pass the first and fail the second.
provider_codex_can_confine() {
  local bin="$1" d="$2/confine-probe" prof
  rm -rf "$d"; mkdir -p "$d/in" "$d/out" || return 1
  echo inside > "$d/in/f"; echo outside > "$d/out/f"
  prof="$(provider_codex_profile "$d/in")"
  ( cd "$d" && run_with_timeout 20 "$bin" sandbox -c 'default_permissions="goblin"' -c "$prof" -- /bin/cat "$d/in/f" ) \
    2>/dev/null | grep -qx inside || { rm -rf "$d"; return 1; }
  if ( cd "$d" && run_with_timeout 20 "$bin" sandbox -c 'default_permissions="goblin"' -c "$prof" -- /bin/cat "$d/out/f" ) \
       2>/dev/null | grep -q outside; then
    rm -rf "$d"; return 1
  fi
  rm -rf "$d"; return 0
}

# Straight from the CLI's own catalog, so the list is whatever this account can use.
provider_codex_models() {
  local bin; bin="$(provider_codex_bin 2>/dev/null || true)"
  [ -n "$bin" ] || { echo '[]'; return 0; }
  "$bin" debug models 2>/dev/null \
    | jq -c '[.models[]? | select((.visibility // "list") == "list") | {id: .slug, label: (.display_name // .slug)}]' 2>/dev/null \
    || echo '[]'
}
