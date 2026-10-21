#!/usr/bin/env bash
# update_install.sh — `goblin update install`: replace this app with the latest
# GitHub release, after checking that it is the release it claims to be.
#
#   goblin update install [--json] [--relaunch]
#
# No Sparkle and no Developer ID required. What is trusted, and why:
#
#   * the release is found with `gh api repos/<slug>/releases/latest`, using the
#     user's own gh login, over TLS, from the repo named in brand.sh;
#   * drafts, prereleases and anything that is not a plain x.y.z tag are refused,
#     and so is a version that is not strictly newer than the one running;
#   * the DMG must match the SHA-256 published next to it (SHA256SUMS, or
#     <dmg>.sha256). That catches a truncated or swapped asset; it is NOT proof of
#     authorship, because whoever can upload the DMG can upload the sum too;
#   * authorship comes from code signing. If the installed app is signed by a real
#     team, the new one must be signed by the SAME Team ID and pass
#     `codesign --verify --deep --strict`. An ad-hoc install (no Developer ID) can
#     only have the checksum, and the README says so;
#   * the bundle identifier and version inside the DMG must match what we expect.
#
# Nothing from the download is executed before all of that passes. Reading its
# Info.plist and asking codesign about it are reads; the first time new code runs
# is the `open` after the swap.
#
# The swap: copy the new app into a staging directory NEXT TO the installed one (the
# same volume, so the renames are atomic), move the old app aside, move the new one
# in, delete the old. A failure between the two renames puts the old one back.
#
# Every external effect sits behind a small function (mount, signature, relaunch)
# so the tests can drive the whole flow offline with a fake `gh`.

UPDATE_TAG_RE='^v?[0-9]+\.[0-9]+\.[0-9]+$'

# --- seams (tests replace these) ---------------------------------------------

# update_dmg_attach <dmg> <mountpoint> — read-only, invisible to Finder, no autorun.
update_dmg_attach() {
  hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$2" "$1" >/dev/null 2>&1
}
update_dmg_detach() {
  hdiutil detach -quiet "$1" >/dev/null 2>&1 || hdiutil detach -quiet -force "$1" >/dev/null 2>&1
}

# update_sig_team <app> — prints the signing Team ID (empty for ad-hoc). rc 1 if
# the bundle is not signed at all.
update_sig_team() {
  local info
  info="$(codesign -dv --verbose=2 "$1" 2>&1)" || return 1
  printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p' | grep -v '^not set$' | head -1
  return 0
}
update_sig_verify() { codesign --verify --deep --strict "$1" >/dev/null 2>&1; }

# update_relaunch <pid> <app> — once <pid> (the app that asked) has quit, open the
# new app. Detached into its own process group (set -m), because launchd kills the
# whole group of a login-item job when the app exits. Gives up waiting after two
# minutes and opens anyway; `open` on an app that is still running only focuses it.
update_relaunch() {
  ( set -m
    nohup /bin/sh -c '
      n=0
      while kill -0 "$1" 2>/dev/null && [ "$n" -lt 600 ]; do n=$((n + 1)); sleep 0.2; done
      sleep 0.5
      exec /usr/bin/open "$2"
    ' goblin-relaunch "$1" "$2" </dev/null >/dev/null 2>&1 &
  )
}

update_plist_get() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

# --- state for cleanup ---------------------------------------------------------

UPD_JSON=false
UPD_TMP=""
UPD_MOUNTED=""
UPD_STAGE=""
UPD_TARGET=""
UPD_LOCKED=false

_upd_fail() { # <code> <message>
  if [ "$UPD_JSON" = true ]; then
    jq -nc --arg c "$1" --arg m "$2" '{ok:false, error:$c, message:$m}'
  else
    printf '%s: %s\n' "$GOBLIN_SLUG" "$2" >&2
  fi
  return 1
}

_upd_log() { log "update: $*" >> "$LOG" 2>/dev/null || true; }

# Runs on every exit path, including SIGTERM from the app's watchdog.
_upd_cleanup() {
  if [ -n "$UPD_MOUNTED" ]; then update_dmg_detach "$UPD_MOUNTED"; UPD_MOUNTED=""; fi
  if [ -n "$UPD_STAGE" ] && [ -d "$UPD_STAGE" ]; then
    # Stopped between the two renames: the installed app is missing, put it back.
    if [ -n "$UPD_TARGET" ] && [ ! -e "$UPD_TARGET" ] && [ -d "$UPD_STAGE/old.app" ]; then
      mv "$UPD_STAGE/old.app" "$UPD_TARGET" 2>/dev/null
    fi
    rm -rf "$UPD_STAGE"
  fi
  UPD_STAGE=""
  if [ -n "$UPD_TMP" ]; then
    # Never recurse into a volume that refused to unmount.
    rmdir "$UPD_TMP/mnt" 2>/dev/null
    [ -e "$UPD_TMP/mnt" ] || rm -rf "$UPD_TMP"
    UPD_TMP=""
  fi
  if [ "$UPD_LOCKED" = true ]; then lock_release; UPD_LOCKED=false; fi
}

# --- the steps ------------------------------------------------------------------

_upd_has_asset() { printf '%s' "$1" | jq -e --arg n "$2" 'any(.assets[]?; .name == $n)' >/dev/null 2>&1; }

# _upd_expected_sum <sums-file> <dmg-name> <is-sums-list> — the published hash.
_upd_expected_sum() {
  if [ "$3" = true ]; then
    # "<hex>  <name>" or "<hex> *<name>" (binary mode), one per line
    awk -v f="$2" '{ n = $2; sub(/^\*/, "", n); if (n == f) { print $1; exit } }' "$1"
  else
    awk 'NF { print $1; exit }' "$1"
  fi | tr '[:upper:]' '[:lower:]' | grep -E '^[0-9a-f]{64}$'
}

update_install_run() {
  local relaunch="$1"

  UPD_TARGET="$(update_target_app)" || {
    _upd_fail not_bundled "This $GOBLIN_SHORT runs from a source checkout, not an app bundle. Update it with: git pull && ./install.sh"
    return 1
  }
  local plist="$UPD_TARGET/Contents/Info.plist" dir
  dir="$(dirname "$UPD_TARGET")"
  [ -f "$plist" ] || { _upd_fail not_bundled "$UPD_TARGET has no Info.plist."; return 1; }
  local bundle_id; bundle_id="$(update_plist_get "$plist" CFBundleIdentifier)"
  [ -n "$bundle_id" ] || { _upd_fail not_bundled "Could not read the installed app's bundle identifier."; return 1; }
  [ -w "$dir" ] || { _upd_fail not_writable "Cannot write to $dir, so the app cannot be replaced there. Install the update by hand, or move the app to a folder you own."; return 1; }
  # A source install (install.sh) schedules the engine it copied to ~/.goblin/app and
  # also builds an app that carries an engine. Replacing only the app would leave the
  # scheduler on the old version, so that install keeps upgrading the way it did.
  if [ -f "$AGENT_PLIST" ] && ! grep -qF "$UPD_TARGET/Contents/Resources/engine/" "$AGENT_PLIST" 2>/dev/null; then
    _upd_fail source_install "The scheduler runs an engine from outside this app (a source install). Update with: git pull && ./install.sh. Or run $GOBLIN_SLUG agent install from this app first to make it the one that runs."
    return 1
  fi
  command -v gh >/dev/null 2>&1 || { _upd_fail no_gh "The GitHub CLI (gh) is needed to download the update."; return 1; }

  # Never swap the engine out from under a review: a running job sources more of
  # lib/ as it goes and would finish on a mixture of two versions.
  local active
  active="$(jobs_counts_json 2>/dev/null | jq -r '.active // 0' 2>/dev/null)"
  [ "${active:-0}" -eq 0 ] 2>/dev/null || { _upd_fail busy "A review is running. Install the update when it has finished."; return 1; }
  goblin_ensure_dirs
  # The scheduler's own lock: no scheduled run can start mid-swap. (It may log a
  # stale-lock sweep to stdout, which must not land in the --json answer.)
  lock_acquire >/dev/null 2>&1 || { _upd_fail busy "A scheduled review run is in progress. Try again in a minute."; return 1; }
  UPD_LOCKED=true

  # 1. what is the latest release?
  local rel tag version draft pre
  rel="$(gh api "repos/$GOBLIN_REPO_SLUG/releases/latest" 2>/dev/null)"
  printf '%s' "$rel" | jq -e '.tag_name | type == "string"' >/dev/null 2>&1 \
    || { _upd_fail no_release "Could not read the latest release of $GOBLIN_REPO_SLUG from GitHub."; return 1; }
  tag="$(printf '%s' "$rel" | jq -r '.tag_name')"
  draft="$(printf '%s' "$rel" | jq -r '.draft // false')"
  pre="$(printf '%s' "$rel" | jq -r '.prerelease // false')"
  if [ "$draft" != false ] || [ "$pre" != false ] || ! printf '%s' "$tag" | grep -qE "$UPDATE_TAG_RE"; then
    _upd_fail prerelease "The latest release ($tag) is a draft or prerelease; only final releases are installed."
    return 1
  fi
  version="${tag#v}"
  update_newer "$version" "$GOBLIN_VERSION" \
    || { _upd_fail not_newer "v$version is not newer than the installed v$GOBLIN_VERSION; nothing to do."; return 1; }

  # 2. which assets?
  local dmg="MergeGoblin-$version.dmg" sums="" sums_list=false
  _upd_has_asset "$rel" "$dmg" || { _upd_fail no_asset "Release $tag has no $dmg."; return 1; }
  if _upd_has_asset "$rel" SHA256SUMS; then sums=SHA256SUMS; sums_list=true
  elif _upd_has_asset "$rel" "$dmg.sha256"; then sums="$dmg.sha256"
  else _upd_fail no_checksum "Release $tag publishes no checksum (SHA256SUMS), so it cannot be verified. Not installing it."; return 1
  fi

  # 3. download into a private temp dir
  UPD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/goblin-update.XXXXXX")" || { _upd_fail io "Could not create a temporary directory."; return 1; }
  mkdir -p "$UPD_TMP/dl" "$UPD_TMP/mnt"
  _upd_log "downloading $tag"
  gh release download "$tag" --repo "$GOBLIN_REPO_SLUG" --pattern "$dmg" --pattern "$sums" \
     --dir "$UPD_TMP/dl" >/dev/null 2>&1
  [ -f "$UPD_TMP/dl/$dmg" ] && [ -f "$UPD_TMP/dl/$sums" ] \
    || { _upd_fail download "The download from GitHub did not complete."; return 1; }

  # 4. checksum, BEFORE the image is even mounted
  local want got
  want="$(_upd_expected_sum "$UPD_TMP/dl/$sums" "$dmg" "$sums_list")"
  [ -n "$want" ] || { _upd_fail checksum "$sums has no valid SHA-256 for $dmg. Not installing it."; return 1; }
  got="$(shasum -a 256 "$UPD_TMP/dl/$dmg" | awk '{print $1}')"
  [ "$want" = "$got" ] \
    || { _upd_log "checksum mismatch for $dmg"; _upd_fail checksum "The download does not match its published checksum. Nothing was installed."; return 1; }

  # 5. look inside, read-only
  update_dmg_attach "$UPD_TMP/dl/$dmg" "$UPD_TMP/mnt" \
    || { _upd_fail mount "Could not open the disk image."; return 1; }
  UPD_MOUNTED="$UPD_TMP/mnt"
  local app="" n=0 f
  for f in "$UPD_MOUNTED"/*.app; do
    [ -d "$f" ] && [ ! -L "$f" ] || continue
    app="$f"; n=$((n + 1))
  done
  [ "$n" -eq 1 ] || { _upd_fail bad_image "The disk image does not contain exactly one app."; return 1; }
  [ "$(update_plist_get "$app/Contents/Info.plist" CFBundleIdentifier)" = "$bundle_id" ] \
    || { _upd_fail wrong_app "The app in the disk image is not $GOBLIN_SHORT ($bundle_id)."; return 1; }
  [ "$(update_plist_get "$app/Contents/Info.plist" CFBundleShortVersionString)" = "$version" ] \
    || { _upd_fail bad_image "The app in the disk image does not say it is v$version."; return 1; }

  # 6. signature
  local have_team new_team signed=false
  have_team="$(update_sig_team "$UPD_TARGET")" || have_team=""
  if new_team="$(update_sig_team "$app")"; then signed=true; else new_team=""; fi
  if [ "$signed" = true ] && ! update_sig_verify "$app"; then
    _upd_fail signature "The new app's code signature does not verify. Not installing it."; return 1
  fi
  if [ -n "$have_team" ] && { [ "$signed" != true ] || [ "$new_team" != "$have_team" ]; }; then
    _upd_fail team "The new app is not signed by the same developer as the installed one (Team ID $have_team). Not installing it."
    return 1
  fi

  # 7. stage next to the installed app (same volume, so the renames are atomic)
  UPD_STAGE="$(mktemp -d "$dir/.merge-goblin-update.XXXXXX")" || { UPD_STAGE=""; _upd_fail io "Could not create a staging directory in $dir."; return 1; }
  ditto "$app" "$UPD_STAGE/new.app" 2>/dev/null || { _upd_fail io "Could not copy the new app out of the disk image."; return 1; }
  update_dmg_detach "$UPD_MOUNTED"; UPD_MOUNTED=""
  if [ "$signed" = true ] && ! update_sig_verify "$UPD_STAGE/new.app"; then
    _upd_fail signature "The copied app no longer verifies. Not installing it."; return 1
  fi

  # 8. swap
  mv "$UPD_TARGET" "$UPD_STAGE/old.app" 2>/dev/null \
    || { _upd_fail swap "Could not move the installed app aside. Nothing was changed."; return 1; }
  if ! mv "$UPD_STAGE/new.app" "$UPD_TARGET" 2>/dev/null; then
    mv "$UPD_STAGE/old.app" "$UPD_TARGET" 2>/dev/null
    _upd_fail swap "Could not move the new app into place; the old one was put back."
    return 1
  fi
  rm -rf "$UPD_STAGE"; UPD_STAGE=""
  _upd_log "installed v$version over v$GOBLIN_VERSION at $UPD_TARGET"

  [ "$relaunch" = true ] && update_relaunch "$PPID" "$UPD_TARGET"

  if [ "$UPD_JSON" = true ]; then
    jq -nc --arg from "$GOBLIN_VERSION" --arg v "$version" --arg app "$UPD_TARGET" \
       --argjson relaunch "$relaunch" --argjson signed "$signed" --arg team "$new_team" \
       '{ok:true, from:$from, version:$v, app:$app, relaunch:$relaunch, signed:$signed, team:$team}'
  else
    printf '%s %s updated: v%s -> v%s\n' "$GOBLIN_EMOJI" "$GOBLIN_NAME" "$GOBLIN_VERSION" "$version"
    if [ "$relaunch" = true ]; then
      printf '  it restarts as soon as the running app quits\n'
    else
      printf '  quit and reopen %s to start the new version\n' "$GOBLIN_SHORT"
    fi
  fi
  return 0
}

cmd_update_install() {
  local relaunch=false
  UPD_JSON=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) UPD_JSON=true ;;
      --relaunch) relaunch=true ;;
      *) echo "usage: $GOBLIN_SLUG update install [--json] [--relaunch]" >&2; return 2 ;;
    esac
    shift
  done
  trap '_upd_cleanup; exit 130' INT TERM HUP
  update_install_run "$relaunch"
  local rc=$?
  _upd_cleanup
  trap - INT TERM HUP
  return "$rc"
}
