#!/usr/bin/env bash
# effort_test.sh — reasoning effort per provider, and opt-in anonymous telemetry.

test_effort_reaches_claude_only_when_set() {
  review_env
  export CLAUDE_FAKE_ARGS_OUT="$GOBLIN_HOME/args.txt"
  "$G" review 2456 --repo acme/widgets >/dev/null 2>&1
  grep -qx -- '--effort' "$CLAUDE_FAKE_ARGS_OUT" && { echo "passed --effort with none chosen"; return 1; }
  "$G" panel set provider-effort claude high >/dev/null 2>&1 || { echo "panel refused high"; return 1; }
  "$G" review 2456 --repo acme/widgets >/dev/null 2>&1
  eq "high" "$(grep -x -A1 -- '--effort' "$CLAUDE_FAKE_ARGS_OUT" | tail -1)" || return 1
  # one review can ask for another level without touching the saved one
  "$G" review 2456 --repo acme/widgets --effort max >/dev/null 2>&1
  eq "max" "$(grep -x -A1 -- '--effort' "$CLAUDE_FAKE_ARGS_OUT" | tail -1)" || return 1
  eq "high" "$(jq -r '.providers.claude.effort' "$GOBLIN_HOME/config.json")" || return 1
  review_env_done
}

test_effort_is_validated_per_provider() {
  review_env
  "$G" panel set provider-effort claude minimal >/dev/null 2>&1 && { echo "claude accepted a codex-only level"; return 1; }
  "$G" panel set provider-effort cursor high    >/dev/null 2>&1 && { echo "cursor accepted an effort"; return 1; }
  "$G" panel set provider-effort claude 'high; rm' >/dev/null 2>&1 && { echo "accepted junk"; return 1; }
  "$G" review 2456 --repo acme/widgets --effort bogus >/dev/null 2>&1; eq 2 "$?" || return 1
  "$G" panel set provider-effort codex minimal >/dev/null 2>&1 || { echo "codex refused minimal"; return 1; }
  review_env_done
}

test_codex_effort_falls_back_to_the_old_key() {
  review_env
  . "$ROOT/lib/brand.sh"; . "$ROOT/lib/paths.sh"; . "$ROOT/lib/core.sh"; . "$ROOT/lib/config.sh"
  eq "medium" "$(provider_effort codex)" || return 1
  cfg_set '.providers.codex.reasoningEffort = "high"'
  eq "high" "$(provider_effort codex)" || return 1
  cfg_set '.providers.codex.effort = "low"'
  eq "low" "$(provider_effort codex)" || return 1
  eq "" "$(provider_effort claude)" || return 1
  review_env_done
}

test_state_shows_the_effort_in_use() {
  review_env
  ( . "$ROOT/lib/brand.sh"; . "$ROOT/lib/paths.sh"; . "$ROOT/lib/core.sh"; . "$ROOT/lib/config.sh"; cfg_backfill_defaults )
  "$G" panel set provider-effort claude xhigh >/dev/null 2>&1
  eq "xhigh" "$(jq -r '.provider.effort' "$GOBLIN_HOME/uistate.json")" || return 1
  eq "xhigh" "$(jq -r '.settings.providers.claude.effort' "$GOBLIN_HOME/uistate.json")" || return 1
  eq "medium" "$(jq -r '.settings.providers.codex.effort' "$GOBLIN_HOME/uistate.json")" || return 1
  review_env_done
}

test_telemetry_is_off_and_sends_nothing_by_default() {
  review_env
  mkdir -p "$GOBLIN_HOME/bin"
  printf '#!/bin/sh\necho "$@" >> "%s/curl.log"\n' "$GOBLIN_HOME" > "$GOBLIN_HOME/bin/curl"; chmod +x "$GOBLIN_HOME/bin/curl"
  export GOBLIN_PATH_FIRST="$GOBLIN_HOME/bin:$GOBLIN_PATH_FIRST"
  "$G" review 2456 --repo acme/widgets >/dev/null 2>&1
  [ -e "$GOBLIN_HOME/curl.log" ] && { echo "called curl with telemetry off"; return 1; }
  [ -e "$GOBLIN_HOME/telemetry-last.json" ] && { echo "recorded a payload with telemetry off"; return 1; }
  eq "off" "$("$G" telemetry status)" || return 1
  review_env_done
}

test_telemetry_payload_has_no_repo_pr_or_person() {
  review_env
  "$G" telemetry on >/dev/null 2>&1
  "$G" panel set provider-effort claude high >/dev/null 2>&1
  "$G" review 2456 --repo acme/widgets --post >/dev/null 2>&1
  local f="$GOBLIN_HOME/telemetry-last.json"
  [ -s "$f" ] || { echo "no payload written"; return 1; }
  eq "claude" "$(jq -r .provider "$f")" || return 1
  eq "high" "$(jq -r .effort "$f")" || return 1
  eq "review" "$(jq -r .event "$f")" || return 1
  grep -qiE 'acme|widgets|2456|\bme\b|github' "$f" && { echo "payload leaks an identifier: $(cat "$f")"; return 1; }
  [ -n "$(jq -r .id "$f")" ] || { echo "no install id"; return 1; }
  "$G" telemetry off >/dev/null 2>&1
  eq "" "$(jq -r '.telemetry.id' "$GOBLIN_HOME/config.json")" || return 1
  [ -e "$f" ] && { echo "payload kept after turning off"; return 1; }
  review_env_done
}
