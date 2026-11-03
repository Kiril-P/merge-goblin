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

test_an_old_claude_without_effort_is_not_given_it() {
  review_env
  export CLAUDE_FAKE_ARGS_OUT="$GOBLIN_HOME/args.txt" CLAUDE_FAKE_NO_EFFORT=1
  "$G" panel set provider-effort claude high >/dev/null 2>&1
  "$G" review 2456 --repo acme/widgets >/dev/null 2>&1
  eq "ready" "$(jq -r .phase "$GOBLIN_HOME/jobs/$(review_job_id)/job.json")" || return 1
  grep -qx -- '--effort' "$CLAUDE_FAKE_ARGS_OUT" && { echo "passed --effort to a claude that lacks it"; return 1; }
  unset CLAUDE_FAKE_NO_EFFORT
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
  cfg_set 'del(.providers.codex.effort) | .providers.codex.reasoningEffort = "high"'
  eq "high" "$(provider_effort codex)" || return 1
  cfg_set '.providers.codex.effort = "low"'
  eq "low" "$(provider_effort codex)" || return 1
  # choosing "Provider default" must stick, not turn back into medium
  cfg_set '.providers.codex.effort = ""'
  eq "" "$(provider_effort codex)" || return 1
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

# A fake collector: curl records what it was asked to send.
telemetry_env() {
  review_env
  mkdir -p "$GOBLIN_HOME/fakebin"
  cat > "$GOBLIN_HOME/fakebin/curl" <<SH
#!/bin/sh
for a in "\$@"; do case "\$prev" in -d) printf '%s\n' "\$a" >> "$GOBLIN_HOME/sent.jsonl" ;; esac; prev="\$a"; done
SH
  chmod +x "$GOBLIN_HOME/fakebin/curl"
  export GOBLIN_PATH_FIRST="$GOBLIN_HOME/fakebin:$GOBLIN_PATH_FIRST"
  export GOBLIN_TELEMETRY_URL_OVERRIDE="https://collector.invalid/v1/events"
  unset DO_NOT_TRACK
}
telemetry_env_done() { export DO_NOT_TRACK=1; unset GOBLIN_TELEMETRY_URL_OVERRIDE; review_env_done; }
wait_sent() { local i=0; while [ ! -s "$GOBLIN_HOME/sent.jsonl" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done; }

test_telemetry_is_on_by_default_and_anonymous() {
  telemetry_env
  eq "on" "$("$G" telemetry status)" || return 1
  "$G" panel set provider-effort claude high >/dev/null 2>&1
  "$G" review 2456 --repo acme/widgets --post >/dev/null 2>&1
  wait_sent
  local f="$GOBLIN_HOME/sent.jsonl"
  [ -s "$f" ] || { echo "nothing sent"; return 1; }
  local r; r="$(grep '"event":"review"' "$f" | tail -1)"
  eq "claude" "$(printf '%s' "$r" | jq -r .provider)" || return 1
  eq "high" "$(printf '%s' "$r" | jq -r .effort)" || return 1
  eq "true" "$(printf '%s' "$r" | jq -r .manual)" || return 1
  grep -qiE 'acme|widgets|2456|"me"|github|fake reviewer' "$f" && { echo "payload leaks an identifier: $(cat "$f")"; return 1; }
  [ -n "$(printf '%s' "$r" | jq -r .id)" ] || { echo "no install id"; return 1; }
  telemetry_env_done
}

test_telemetry_off_sends_nothing_and_forgets_the_id() {
  telemetry_env
  "$G" panel set telemetry off >/dev/null 2>&1 || { echo "panel refused off"; return 1; }
  eq "off" "$("$G" telemetry status)" || return 1
  "$G" review 2456 --repo acme/widgets >/dev/null 2>&1; sleep 0.5
  [ -e "$GOBLIN_HOME/sent.jsonl" ] && { echo "sent with telemetry off"; return 1; }
  [ -e "$GOBLIN_HOME/telemetry-id" ] && { echo "kept the install id"; return 1; }
  eq "false" "$(jq -r '.settings.telemetry.enabled' "$GOBLIN_HOME/uistate.json")" || return 1
  # DO_NOT_TRACK wins over a choice of "on"
  "$G" telemetry on >/dev/null 2>&1
  DO_NOT_TRACK=1 "$G" review 2456 --repo acme/widgets >/dev/null 2>&1; sleep 0.5
  [ -e "$GOBLIN_HOME/sent.jsonl" ] && { echo "ignored DO_NOT_TRACK"; return 1; }
  telemetry_env_done
}

test_usage_log_counts_actions_not_reads_or_arguments() {
  review_env
  "$G" status --json >/dev/null 2>&1
  "$G" panel set provider-effort claude high >/dev/null 2>&1
  "$G" review 2456 --repo acme/widgets >/dev/null 2>&1
  "$G" telemetry ui settings.reviewer >/dev/null 2>&1
  "$G" telemetry ui 'bad name; rm' >/dev/null 2>&1
  local log="$GOBLIN_HOME/usage.log"
  grep -q ' panel.provider-effort$' "$log" || { echo "panel key not counted"; cat "$log"; return 1; }
  grep -q ' review$' "$log"                || { echo "review not counted"; return 1; }
  grep -q ' ui.settings.reviewer$' "$log"  || { echo "screen not counted"; return 1; }
  grep -qE ' status$|acme|2456|bad' "$log" && { echo "counted a read or an argument: $(cat "$log")"; return 1; }
  eq 1 "$(grep -c ' review$' "$log")" || return 1
  review_env_done
}

test_daily_snapshot_has_settings_and_usage_once_a_day() {
  telemetry_env
  ( . "$ROOT/lib/brand.sh"; . "$ROOT/lib/paths.sh"; . "$ROOT/lib/core.sh"; . "$ROOT/lib/config.sh"; cfg_backfill_defaults )
  "$G" telemetry ui popover >/dev/null 2>&1
  ( . "$ROOT/lib/brand.sh"; . "$ROOT/lib/paths.sh"; . "$ROOT/lib/core.sh"; . "$ROOT/lib/config.sh"; . "$ROOT/lib/state.sh"
    . "$ROOT/lib/telemetry.sh"; export PATH="$GOBLIN_PATH_FIRST:$PATH"; telemetry_daily; telemetry_daily )
  wait_sent
  eq 1 "$(grep -c '"event":"daily"' "$GOBLIN_HOME/sent.jsonl")" || return 1
  local d; d="$(grep '"event":"daily"' "$GOBLIN_HOME/sent.jsonl")"
  eq 1 "$(printf '%s' "$d" | jq '.usage["ui.popover"]')" || return 1
  eq 2 "$(printf '%s' "$d" | jq '.counts.repos')" || return 1
  eq "comment" "$(printf '%s' "$d" | jq -r '.settings.verdictMode')" || return 1
  printf '%s' "$d" | grep -qiE 'acme|widgets|"me"' && { echo "daily leaks: $d"; return 1; }
  telemetry_env_done
}

test_insights_reports_models_failures_and_unused_screens() {
  review_env
  "$G" review 2456 --repo acme/widgets >/dev/null 2>&1
  "$G" telemetry ui popover >/dev/null 2>&1
  printf '{"at":%s,"number":7,"title":"t","url":"u","costUsd":0,"status":"failed","reason":"timeout","repo":"acme/widgets","provider":"codex","model":"gpt-x","effort":"high"}\n' \
    "$(date +%s)" >> "$GOBLIN_HOME/events.jsonl"
  local j; j="$("$G" insights --json)" || { echo "insights failed"; return 1; }
  eq 2 "$(printf '%s' "$j" | jq '.reviews.total')" || return 1
  eq "timeout" "$(printf '%s' "$j" | jq -r '.failures[0].kind')" || return 1
  eq 100 "$(printf '%s' "$j" | jq '[.byModel[] | select(.model == "gpt-x")][0].failRatePct')" || return 1
  printf '%s' "$j" | jq -e '.unusedScreens | index("popover") | not' >/dev/null || { echo "popover listed as unused"; return 1; }
  printf '%s' "$j" | jq -e '.unusedScreens | index("settings.about")' >/dev/null || { echo "about not listed as unused"; return 1; }
  "$G" insights >/dev/null 2>&1 || { echo "text report failed"; return 1; }
  review_env_done
}
