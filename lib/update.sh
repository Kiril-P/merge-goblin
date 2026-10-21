#!/usr/bin/env bash
# update.sh — tell people a newer Goblin exists. Checking NEVER installs anything.
#
# The check is notify-only. Applying an update means replacing the code that is
# currently executing, and a single bad push would then break every teammate at
# once with nobody having chosen to accept it. So this only ever writes a flag.
# Installing is a separate, explicit act: `goblin update install` (the app's
# "Install update" button), which lives in update_install.sh and verifies what it
# downloads before touching anything. A source checkout upgrades the way it always
# did: git pull, ./install.sh.
#
# The check is one authenticated `gh api` call per day, to this project's own
# repo, piggybacked on a scheduled run that was going to talk to GitHub anyway.
# Every failure path is silent: offline, rate-limited, repo moved or renamed all
# leave the Goblin doing its job without a word about updates.

UPDATE_CHECK_DEFAULT_SECS=86400

# update_newer <candidate> <current> — 0 if candidate is strictly newer.
#
# Compares dot-separated numeric fields, missing fields counting as 0 (so 0.5
# beats 0.4.9). Non-numeric suffixes are stripped rather than guessed at: an
# "0.5.0-rc1" tag compares equal to 0.5.0 and therefore never nags someone into
# a prerelease, which is the safe direction to be wrong in.
update_newer() {
  local a="${1#v}" b="${2#v}" i ai bi
  [ -n "$a" ] || return 1
  for i in 1 2 3; do
    # Truncate at the first non-digit rather than deleting non-digits: stripping
    # them out of "0-rc1" would leave "01" and read a prerelease as patch 1.
    ai="$(printf '%s' "$a" | cut -d. -f"$i" | sed 's/[^0-9].*$//')"; ai="${ai:-0}"
    bi="$(printf '%s' "$b" | cut -d. -f"$i" | sed 's/[^0-9].*$//')"; bi="${bi:-0}"
    [ "$ai" -gt "$bi" ] 2>/dev/null && return 0
    [ "$ai" -lt "$bi" ] 2>/dev/null && return 1
  done
  return 1
}

# update_target_app — the .app bundle this engine was shipped inside, or rc 1.
#
# The app carries its engine at <App>.app/Contents/Resources/engine, so GOBLIN_APP
# says which bundle is running (also through the Homebrew `goblin` symlink, which
# bin/goblin resolves). A source checkout has no bundle to replace.
update_target_app() {
  case "${GOBLIN_APP:-}" in */Contents/Resources/engine) ;; *) return 1 ;; esac
  local app="${GOBLIN_APP%/Contents/Resources/engine}"
  case "$app" in /*.app) ;; *) return 1 ;; esac
  [ -d "$app" ] || return 1
  printf '%s' "$app"
}

# The version an upgrade would actually give you.
#
# An app bundle upgrades from a published release, so it asks for the latest one
# (GitHub's "latest" never includes drafts or prereleases; the filter says so
# anyway). A source checkout upgrades with `git pull`, so it reads the version on
# the default branch instead: tags could sit ahead of or behind what a pull
# installs, and the point is to describe the upgrade the user will perform.
update_remote_version() {
  if update_target_app >/dev/null; then
    gh api "repos/$GOBLIN_REPO_SLUG/releases/latest" \
       --jq 'select((.draft | not) and (.prerelease | not)) | .tag_name' 2>/dev/null \
      | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1
    return 0
  fi
  gh api "repos/$GOBLIN_REPO_SLUG/contents/lib/brand.sh" \
     -H "Accept: application/vnd.github.raw" 2>/dev/null \
    | grep -m1 '^GOBLIN_VERSION=' \
    | sed -e 's/^GOBLIN_VERSION=//' -e 's/["'\'']//g' -e 's/[[:space:]#].*$//' \
    | tr -cd '0-9.'
}

update_read() { cat "$UPDATE_STATE" 2>/dev/null; }

update_field() {  # <jq-filter> <default>
  local v; v="$(update_read | jq -r "$1" 2>/dev/null)"
  if [ -z "$v" ] || [ "$v" = "null" ]; then printf '%s' "$2"; else printf '%s' "$v"; fi
}

# Cached answer only — no network. Prints the newer version, or nothing.
update_available() {
  [ "$(update_field '.available' false)" = true ] || return 1
  # A cached "available" from before an upgrade must not outlive it, so re-check
  # the recorded version against the one running right now.
  local latest; latest="$(update_field '.latest' '')"
  update_newer "$latest" "$GOBLIN_VERSION" || return 1
  printf '%s' "$latest"
}

update_check_due() {
  local every last now
  every="$(cfg_get '.update.checkEverySecs' "$UPDATE_CHECK_DEFAULT_SECS")"
  last="$(update_field '.checkedAt' 0)"
  now="$(now_epoch)"
  [ $((now - last)) -ge "${every:-$UPDATE_CHECK_DEFAULT_SECS}" ] 2>/dev/null
}

# update_check [--force] — throttled, silent, and never fails its caller.
update_check() {
  [ "${1:-}" = "--force" ] || {
    [ "$(cfg_get '.update.notify' true)" = true ] || return 0
    update_check_due || return 0
  }
  goblin_ensure_dirs

  local latest avail=false
  latest="$(update_remote_version)"
  # Stamp checkedAt even when the lookup failed, or an offline machine would
  # retry on every single run for as long as it stays offline.
  if [ -n "$latest" ] && update_newer "$latest" "$GOBLIN_VERSION"; then avail=true; fi
  [ -n "$latest" ] || latest="$(update_field '.latest' '')"

  local url="$GOBLIN_REPO_URL"
  update_target_app >/dev/null && url="$GOBLIN_REPO_URL/releases/latest"
  jq -nc --arg latest "$latest" --arg current "$GOBLIN_VERSION" \
     --arg url "$url" --argjson avail "$avail" \
     --argjson at "$(now_epoch)" \
     '{checkedAt:$at, latest:$latest, current:$current, available:$avail, url:$url}' \
     > "$UPDATE_STATE.tmp" 2>/dev/null \
    && mv "$UPDATE_STATE.tmp" "$UPDATE_STATE" \
    || rm -f "$UPDATE_STATE.tmp" 2>/dev/null
  return 0
}

# What to tell someone to do about it. There is no recorded clone path, so a
# source install names the repo rather than pretending to know where it is.
update_instructions() {
  if update_target_app >/dev/null; then
    printf 'choose Install update in the %s menu, or run: %s update install' "$GOBLIN_SHORT" "$GOBLIN_SLUG"
  else
    printf 'in your %s clone: git pull && ./install.sh' "$GOBLIN_SLUG"
  fi
}

# goblin update [check]                        look for a newer version; installs nothing
# goblin update install [--json] [--relaunch]  replace this app with the latest release
cmd_update() {
  case "${1:-}" in
    install) shift; . "$LIB_DIR/update_install.sh"; cmd_update_install "$@"; return $? ;;
    ""|check) ;;
    *) echo "usage: $GOBLIN_SLUG update [check | install [--json] [--relaunch]]" >&2; return 2 ;;
  esac
  cfg_ensure; cfg_backfill_defaults
  update_check --force
  local latest
  if latest="$(update_available)"; then
    printf '%s %s v%s → v%s is out\n  %s\n' \
      "$GOBLIN_EMOJI" "$GOBLIN_NAME" "$GOBLIN_VERSION" "$latest" "$(update_instructions)"
    return 0
  fi
  local seen; seen="$(update_field '.latest' '')"
  if [ -z "$seen" ]; then
    printf 'could not reach %s — nothing changed\n' "$GOBLIN_REPO_SLUG"
  else
    printf '%s %s v%s is current\n' "$GOBLIN_EMOJI" "$GOBLIN_NAME" "$GOBLIN_VERSION"
  fi
}
