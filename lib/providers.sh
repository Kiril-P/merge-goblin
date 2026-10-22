#!/usr/bin/env bash
# providers.sh — the provider registry. The engine talks only to this file, so
# adding a new AI CLI means dropping one adapter into lib/providers/.

GOBLIN_PROVIDERS="claude codex cursor"

providers_load() {
  local p
  for p in $GOBLIN_PROVIDERS; do
    # shellcheck source=/dev/null
    [ -f "$PROVIDER_DIR/$p.sh" ] && . "$PROVIDER_DIR/$p.sh"
  done
}

# Map a CLI's error text onto a stable kind so the engine can react (a quota
# error should fall back to another provider; a transient one should retry).
#
# Callers pass stderr AND the tail of stdout: claude reports a usage limit inside its
# JSON result with nothing on stderr, and codex reports errors as stream events. Most
# real failures used to land in "other" (45 of 55 on one install), which told nobody
# anything. "Connection lost, reconnecting…" from cursor was the commonest of them.
provider_classify_error() {
  local t; t="$(lc "${1:-}")"
  # Status codes only as whole numbers: "duration_ms":4290 is not a 429.
  if printf '%s' "$t" | grep -qE '(^|[^0-9])429([^0-9]|$)'; then echo quota; return 0; fi
  case "$t" in
    *"rate limit"*|*"rate_limit"*|*"quota"*|*"usage limit"*|*"usage_limit"*|*"hit your limit"*|\
    *"limit reached"*|*"too many requests"*|*"out of credits"*|*"credit balance"*) echo quota; return 0 ;;
    *"not logged in"*|*"unauthorized"*|*"unauthenticated"*|*"authentication"*|*"invalid api key"*|\
    *"please log in"*|*"please login"*|*"login required"*|*"/login"*|*"session expired"*) echo auth; return 0 ;;
  esac
  if printf '%s' "$t" | grep -qE '(^|[^0-9])401([^0-9]|$)'; then echo auth; return 0; fi
  case "$t" in
    *"timeout"*|*"timed out"*|*"econnreset"*|*"econnrefused"*|*"enotfound"*|*"getaddrinfo"*|\
    *"connection lost"*|*"connection reset"*|*"connection refused"*|*"connection closed"*|\
    *"reconnecting"*|*"could not resolve"*|*"fetch failed"*|*"network"*|*"socket"*|*"offline"*|\
    *"overloaded"*|*"service unavailable"*|*"bad gateway"*) echo transient; return 0 ;;
  esac
  if printf '%s' "$t" | grep -qE '(^|[^0-9])5(0[0-9]|29)([^0-9]|$)'; then echo transient; return 0; fi
  echo other
}

# provider_error_text <raw-dir> — what to classify: stderr, plus the error fields of
# stdout. Only the error fields: the rest of stdout is the model talking, and a model
# reviewing rate-limiting code says "rate limit" without being rate limited.
provider_error_text() {
  local raw="$1"
  head -c 4000 "$raw/stderr.txt" 2>/dev/null
  if [ -f "$raw/stdout.json" ]; then
    printf '\n'
    jq -r 'select(type == "object")
           | if (.is_error == true) then (.result // .error // .message // "" | tostring)
             else (.error // "" | if type == "object" then (.message // "") else . end | tostring) end' \
      "$raw/stdout.json" 2>/dev/null | head -c 2000
  fi
  if [ -f "$raw/stdout.jsonl" ]; then
    printf '\n'
    jq -r 'select(type == "object") | select((.type // "" | tostring) | test("error|fail"))
           | (.message // .error.message // .error // "" | tostring)' \
      "$raw/stdout.jsonl" 2>/dev/null | tail -c 2000
  fi
  return 0
}

# provider_error_line <raw-dir> — the most telling line of a failure, for the log and
# the "details" a person can expand. A CLI that retried six times prints six lines;
# the last non-blank one is what finally happened.
provider_error_line() {
  local raw="$1" line
  line="$(LC_ALL=C tr -cd '\11\12\15\40-\176' < "$raw/stderr.txt" 2>/dev/null \
    | grep -v '^[[:space:]]*$' | tail -n 1 | head -c 300)"
  [ -n "$line" ] || line="$(provider_error_text "$raw" | LC_ALL=C tr -cd '\11\12\15\40-\176' \
    | grep -v '^[[:space:]]*$' | tail -n 1 | head -c 300)"
  printf '%s' "$line"
}

# --- usage-limit cooldown ----------------------------------------------------
# A provider that hit its usage limit is left alone until it resets (or an hour, when
# the CLI doesn't say), and scheduled runs use providerFallback meanwhile. Retrying it
# every interval used to fail every PR in turn and mark each one as stuck, for a fault
# that was nobody's PR. State: ~/.goblin/provider-cooldown.json {"claude": until}.
provider_cooldown_file() { printf '%s/provider-cooldown.json' "$GOBLIN_HOME"; }

provider_cooldown_until() {
  local f; f="$(provider_cooldown_file)"
  [ -f "$f" ] || { printf 0; return 0; }
  local u; u="$(jq -r --arg p "$1" '.[$p] // 0 | tonumber? // 0' "$f" 2>/dev/null)"
  case "$u" in ''|*[!0-9]*) u=0 ;; esac
  printf '%s' "$u"
}

provider_cooling() { [ "$(provider_cooldown_until "$1")" -gt "$(now_epoch)" ]; }

# provider_cooldown_set <provider> <error-text> — until the reset the CLI names
# ("…limit reached|1792670400"), else failure.quotaCooldownSecs (1 hour). Prints until.
provider_cooldown_set() {
  local p="$1" text="${2:-}" f now until def
  f="$(provider_cooldown_file)"; now="$(now_epoch)"
  def="$(cfg_get '.failure.quotaCooldownSecs' 3600)"
  case "$def" in ''|*[!0-9]*) def=3600 ;; esac
  until="$(printf '%s' "$text" | grep -oE '\|[0-9]{10}' | head -n 1 | tr -d '|')"
  # only a reset in the next day is believable; anything else is a number that
  # happened to follow a pipe
  if [ -z "$until" ] || [ "$until" -le "$now" ] || [ "$until" -gt $((now + 86400)) ]; then
    until=$((now + def))
  fi
  [ -f "$f" ] && jq -e 'type == "object"' "$f" >/dev/null 2>&1 || echo '{}' > "$f"
  jq --arg p "$p" --argjson u "$until" '.[$p] = $u' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  printf '%s' "$until"
}

provider_cooldown_clear() {
  local f; f="$(provider_cooldown_file)"
  [ -f "$f" ] || return 0
  jq --arg p "$1" 'del(.[$p])' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
}

providers_probe_all() {
  providers_load
  local p out=""
  for p in $GOBLIN_PROVIDERS; do
    out="$out$("provider_${p}_probe" 2>/dev/null)
"
  done
  printf '%s' "$out" | jq -s '.'
}

providers_report() {
  local cur; cur="$(cfg_get '.provider' 'claude')"
  providers_probe_all | jq -r --arg cur "$cur" '.[] |
    (if .name == $cur then "▸ " else "  " end) +
    (.name | . + (" " * (8 - length))) +
    (if .available then (if .authed then "ready  " else "no auth" end) else "missing" end) +
    "  " + ((.authMode // "") | .[0:14] | . + (" " * (16 - length))) +
    (if .costKnown then "cost: yes" else "cost: n/a" end) +
    (if (.note // "") != "" then "   " + .note else "" end)'
}

providers_set() {
  local want="$1" ok=false p
  for p in $GOBLIN_PROVIDERS; do [ "$p" = "$want" ] && ok=true; done
  if [ "$ok" != true ]; then
    echo "unknown provider '$want' (choose: $GOBLIN_PROVIDERS)" >&2; return 2
  fi
  providers_load
  local probe; probe="$("provider_${want}_probe")"
  if [ "$(printf '%s' "$probe" | jq -r '.available')" != "true" ]; then
    echo "$want is not installed: $(printf '%s' "$probe" | jq -r '.note')" >&2; return 1
  fi
  if [ "$(printf '%s' "$probe" | jq -r '.authed')" != "true" ]; then
    echo "warning: $want is installed but not authenticated — $(printf '%s' "$probe" | jq -r '.note')" >&2
  fi
  cfg_set --arg p "$want" '.provider = $p'
  status_set '{}'
  echo "provider set to $want"
}

# The provider to use for this run: the configured one if usable, else the first
# healthy entry in providerFallback. Prints the chosen id, or nothing.
#
# A provider resting after a usage limit (provider_cooling) is passed over, so the
# fallback takes its place until the limit resets. --allow-cooling ignores the rest:
# for a person who asked for a review, and to tell "resting" apart from "unusable".
providers_pick() {
  providers_load
  local want fallbacks p probe cool=false
  [ "${1:-}" = "--allow-cooling" ] && cool=true
  want="$(cfg_get '.provider' 'claude')"
  fallbacks="$(cfg_read | jq -r '.providerFallback[]?' 2>/dev/null)"
  for p in $want $fallbacks; do
    case " $GOBLIN_PROVIDERS " in *" $p "*) ;; *) continue ;; esac
    [ "$cool" = false ] && provider_cooling "$p" && continue
    probe="$("provider_${p}_probe" 2>/dev/null)"
    if [ "$(printf '%s' "$probe" | jq -r '.available and .authed')" = "true" ]; then
      printf '%s' "$p"; return 0
    fi
  done
  return 1
}

# providers_models <name> [--refresh] -> [{id,label}]
#
# What a person may choose from, so the app offers a menu of real models rather than
# a text box. Cached a day: listing them runs the provider's CLI, which is slow. An
# empty answer is never cached, or one bad run would hide the list until it expired.
providers_models() {
  local name="$1" refresh="${2:-}" cache out age
  case " $GOBLIN_PROVIDERS " in *" $name "*) ;; *) echo '[]'; return 2 ;; esac
  cache="$GOBLIN_HOME/models-$name.json"
  if [ "$refresh" != "--refresh" ] && [ -f "$cache" ]; then
    age=$(( $(now_epoch) - $(stat -f %m "$cache" 2>/dev/null || echo 0) ))
    if [ "$age" -lt 86400 ] && jq -e 'length > 0' "$cache" >/dev/null 2>&1; then cat "$cache"; return 0; fi
  fi
  providers_load
  out="$("provider_${name}_models" 2>/dev/null)"
  if printf '%s' "$out" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    mkdir -p "$GOBLIN_HOME" 2>/dev/null
    printf '%s' "$out" | jq -c . | atomic_write "$cache"
    printf '%s' "$out" | jq -c .
  elif [ -f "$cache" ] && jq -e 'length > 0' "$cache" >/dev/null 2>&1; then
    cat "$cache"          # the CLI failed this time: a stale list beats none
  else
    echo '[]'
  fi
}
