#!/usr/bin/env bash
# app.sh — the menu bar app: build, install, remove, login item.
#
# The app is a SwiftPM package (Package.swift, Sources/Goblin) and build.sh turns it
# into a signed bundle that carries the engine inside it. This file is the thin
# wrapper that puts that bundle where macOS expects it and manages the login item.
# It needs a checkout to build from; an app installed from a release has nothing to
# rebuild and does not need this.
#
# If the Swift toolchain is missing the build prints the one-line fix and SKIPS,
# because a missing menu bar app must never be the reason an install fails — the
# CLI works without it.
#
# Written for bash 3.2, which is what /bin/bash on macOS actually is.

APP_EXEC_NAME="GoblinBar"
# The running app passes its own path (a cask or a dragged DMG lives in /Applications;
# install.sh puts it in ~/Applications). From a terminal, take whichever exists.
if [ -n "${GOBLIN_APP_BUNDLE:-}" ]; then
  APP_BUNDLE="$GOBLIN_APP_BUNDLE"
elif [ ! -d "$HOME/Applications/$GOBLIN_SHORT.app" ] && [ -d "/Applications/$GOBLIN_SHORT.app" ]; then
  APP_BUNDLE="/Applications/$GOBLIN_SHORT.app"
else
  APP_BUNDLE="$HOME/Applications/$GOBLIN_SHORT.app"
fi

# LaunchServices caches an app's Info.plist by path, so a bundle replaced in place
# has to be re-registered or macOS keeps answering from the stale copy.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Same sanitiser as goblin_agent_label() in paths.sh, so the two labels agree on
# what a username is. The login-item label is what the app itself computes
# (LoginItem.label in Store.swift): one name to grep for in `launchctl list`.
app_bundle_id() {
  local u
  u="$(id -un 2>/dev/null | tr -cd '[:alnum:]._-')"
  printf 'com.%s.%s.bar' "${u:-user}" "$GOBLIN_SLUG"
}

app_bar_plist() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$(app_bundle_id)"; }
app_exec_path() { printf '%s/Contents/MacOS/%s' "$APP_BUNDLE" "$APP_EXEC_NAME"; }

# --- build ----------------------------------------------------------------

# GOBLIN_SRC is the checkout to build from (install.sh sets it); running from a
# checkout, GOBLIN_APP already is one.
app_build() {
  local src="${GOBLIN_SRC:-$GOBLIN_APP}" stage
  if [ ! -x "$src/build.sh" ] || [ ! -f "$src/Package.swift" ]; then
    echo "  ! no app sources at $src — rebuild from a git checkout of $GOBLIN_SLUG" >&2
    return 1
  fi
  if ! command -v swift >/dev/null 2>&1; then
    cat >&2 <<EOF
  ! the menu bar app needs the Swift toolchain, which comes with the Xcode command line tools:

        xcode-select --install

    skipping the app for now — the CLI works without it.
EOF
    return 1
  fi
  stage="$(mktemp -d)" || return 1
  if ! "$src/build.sh" --out "$stage" >&2; then
    rm -rf "$stage"; echo "  ✗ the app did not build" >&2; return 1
  fi
  app_swap_bundle "$stage/$GOBLIN_SHORT.app"
  local rc=$?
  rm -rf "$stage"
  return $rc
}

# app_swap_bundle <staged.app> — replace the installed bundle with a built one.
#
# The LaunchAgent is booted out for the duration. Without that its KeepAlive
# relaunches the app from a path that is being deleted, which is how the bundle got
# corrupted in the first place; it also means the running app keeps the OLD code
# until something restarts it, so users saw fixes "not apply" after a rebuild.
app_swap_bundle() {
  local stage="$1" label uid plist_agent was_loaded=false
  label="$(app_bundle_id)"; uid="$(id -u)"
  plist_agent="$(app_bar_plist)"

  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    was_loaded=true
    launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  fi
  killall "$APP_EXEC_NAME" 2>/dev/null || true

  # Give the process time to actually exit. Deleting a bundle out from under a
  # running app is what EPERMs.
  local i=0
  while pgrep -x "$APP_EXEC_NAME" >/dev/null 2>&1 && [ "$i" -lt 25 ]; do
    sleep 0.2; i=$((i + 1))
  done
  pgrep -x "$APP_EXEC_NAME" >/dev/null 2>&1 && killall -9 "$APP_EXEC_NAME" 2>/dev/null || true

  [ -x "$LSREGISTER" ] && [ -d "$APP_BUNDLE" ] && "$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1

  mkdir -p "$(dirname "$APP_BUNDLE")"
  rm -rf "$APP_BUNDLE"
  # ditto rather than mv: it copies across filesystems and preserves the bundle's
  # metadata and the signature we just applied.
  if ! ditto "$stage" "$APP_BUNDLE" 2>/dev/null; then
    echo "  ✗ could not install the bundle to $APP_BUNDLE" >&2
    [ "$was_loaded" = true ] && launchctl bootstrap "gui/$uid" "$plist_agent" 2>/dev/null || true
    return 1
  fi

  [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1

  # Bring the bar back only if it was running before, so a rebuild does not launch
  # an app the user had deliberately quit.
  if [ "$was_loaded" = true ] && [ -f "$plist_agent" ]; then
    launchctl bootstrap "gui/$uid" "$plist_agent" 2>/dev/null || true
  fi
  return 0
}

# --- install / remove -----------------------------------------------------

app_install() {
  app_build || return 1
  echo "        open it from Spotlight, or run: open -a \"$APP_BUNDLE\""
  echo "        turn on 'Start at login' in its menu to have it there every morning"
}

app_remove() {
  local plist label
  plist="$(app_bar_plist)"
  label="$(app_bundle_id)"

  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$plist"
  killall "$APP_EXEC_NAME" 2>/dev/null || true
  if [ -d "$APP_BUNDLE" ]; then
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1
    rm -rf "$APP_BUNDLE"
    echo "removed $APP_BUNDLE"
  else
    echo "the menu bar app was not installed"
  fi
}

# --- login item -----------------------------------------------------------

app_login_item_on() {
  local plist label exec_path uid
  exec_path="$(app_exec_path)"
  if [ ! -x "$exec_path" ]; then
    echo "the menu bar app is not built — run: $GOBLIN_SLUG app rebuild" >&2
    return 1
  fi

  plist="$(app_bar_plist)"
  label="$(app_bundle_id)"
  uid="$(id -u)"
  mkdir -p "$HOME/Library/LaunchAgents" || return 1

  sed -e "s|__LABEL__|$label|g" -e "s|__EXEC__|$exec_path|g" \
      "$TEMPLATE_DIR/bar-agent.plist.tmpl" > "$plist"
  if ! plutil -lint "$plist" >/dev/null 2>&1; then
    rm -f "$plist"
    echo "generated login item plist is invalid" >&2
    return 1
  fi

  # A persistent `disable` override from an earlier 'off' would silently win over
  # bootstrap, so clear it first.
  launchctl enable "gui/$uid/$label" 2>/dev/null || true

  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    # Already loaded. Only replace it when the app is NOT up: bootout would quit
    # a running menu bar item under the user's cursor, and the user just asked for
    # more of it, not less.
    if ! pgrep -x "$APP_EXEC_NAME" >/dev/null 2>&1; then
      launchctl bootout "gui/$uid/$label" 2>/dev/null || true
      launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null || true
    fi
  else
    launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null || true
  fi

  echo "the $GOBLIN_SHORT will open at login"
}

app_login_item_off() {
  local plist
  plist="$(app_bar_plist)"

  # Only the plist is removed; the loaded job is left alone deliberately. Booting
  # it out would terminate the app that is running right now — the user unticked
  # "Start at login", which is about tomorrow, not about closing the thing they
  # are looking at. With the plist gone, launchd does not load it next login.
  rm -f "$plist"
  echo "the $GOBLIN_SHORT will no longer open at login"
}

app_login_item_status() {
  if [ -f "$(app_bar_plist)" ]; then echo "on"; else echo "off"; fi
}

# --- dispatcher -----------------------------------------------------------

# `goblin ui` / `goblin open` — muscle memory, and what install.sh advertises. The
# panel is no longer a served web page, so this just brings the app forward.
cmd_ui() {
  case "${1:-}" in
    --stop)
      # Replaces `pkill -f server.py`, which matched on an absolute path and so
      # silently failed to stop a panel started from a different checkout.
      osascript - "$(app_bundle_id)" >/dev/null 2>&1 <<'APPLESCRIPT' || killall "$APP_EXEC_NAME" 2>/dev/null || true
on run argv
	tell application id (item 1 of argv) to quit
end run
APPLESCRIPT
      echo "closed"; return 0 ;;
    --url|--port|--no-open)
      echo "the panel is part of the app now — there is no URL or port" >&2
      echo "open it with: $GOBLIN_SLUG ui" >&2
      return 2 ;;
  esac

  if [ ! -x "$(app_exec_path)" ]; then
    echo "the $GOBLIN_SHORT app is not built yet — run: $GOBLIN_SLUG app rebuild" >&2
    return 1
  fi
  open "$APP_BUNDLE" 2>/dev/null || {
    echo "could not open $APP_BUNDLE" >&2; return 1; }
}

# Open straight onto the wizard. Used by `goblin setup` and printed by install.sh
# when setup is still incomplete.
cmd_app_open_wizard() {
  cfg_ensure; cfg_backfill_defaults
  if [ ! -x "$(app_exec_path)" ]; then
    # No GUI available: say exactly what to do rather than dead-ending.
    echo "the app is not built (run: $GOBLIN_SLUG app rebuild)."
    echo "you can also set up from the terminal:"
    echo "  $GOBLIN_SLUG accounts                      # pick one"
    echo "  $GOBLIN_SLUG panel set identity <login>"
    echo "  $GOBLIN_SLUG provider list                 # pick one that says ready"
    echo "  $GOBLIN_SLUG provider use <id>"
    echo "  $GOBLIN_SLUG repos search -q <name>"
    echo "  $GOBLIN_SLUG repos add owner/name"
    echo "  $GOBLIN_SLUG panel set setup-complete 1"
    return 1
  fi
  cmd_ui
}

cmd_app() {
  local sub="${1:-status}"
  shift 2>/dev/null || true

  case "$sub" in
    build|rebuild) app_build ;;
    open-wizard)   cmd_app_open_wizard ;;
    install)       app_install ;;
    remove|uninstall) app_remove ;;
    path)          echo "$APP_BUNDLE" ;;
    label)         app_bundle_id; echo ;;
    login-item)
      case "${1:-status}" in
        on)     app_login_item_on ;;
        off)    app_login_item_off ;;
        status) app_login_item_status ;;
        *) echo "usage: $GOBLIN_SLUG app login-item [on|off|status]" >&2; return 2 ;;
      esac ;;
    status)
      echo "bundle:     $APP_BUNDLE"
      echo "installed:  $([ -x "$(app_exec_path)" ] && echo yes || echo no)"
      echo "running:    $(pgrep -x "$APP_EXEC_NAME" >/dev/null 2>&1 && echo yes || echo no)"
      echo "identifier: $(app_bundle_id)"
      echo "login item: $(app_login_item_status)" ;;
    *)
      echo "usage: $GOBLIN_SLUG app [status|rebuild|install|remove|path|login-item on|off]" >&2
      return 2 ;;
  esac
}
