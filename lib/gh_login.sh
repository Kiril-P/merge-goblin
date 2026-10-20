#!/usr/bin/env bash
# gh_login.sh — sign in to GitHub from the app, with no terminal.
#
#   goblin github-login start    begin the browser (device-code) flow; prints JSON
#   goblin github-login status   {"state":"waiting"|"done"|"failed","code":"ABCD-1234"}
#   goblin github-login cancel
#
# This only drives `gh auth login --web`: the one-time code is shown by the app, the
# person approves it in their browser, and gh stores the token in its own keychain
# entry exactly as if they had done it in a terminal. The Goblin never sees the token
# until it asks `gh auth token`, as it always has.

GH_LOGIN_OUT="$GOBLIN_HOME/login.out"
GH_LOGIN_PID="$GOBLIN_HOME/login.pid"

gh_login_code() { grep -oE '[A-Z0-9]{4}-[A-Z0-9]{4}' "$GH_LOGIN_OUT" 2>/dev/null | head -1; }

gh_login_running() {
  local p; p="$(cat "$GH_LOGIN_PID" 2>/dev/null)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

gh_login_state() {
  local code; code="$(gh_login_code)"
  if gh_login_running; then
    jq -nc --arg c "$code" '{state:"waiting", code:$c}'
  elif [ -f "$GH_LOGIN_OUT" ] && ! grep -q 'Logged in as' "$GH_LOGIN_OUT" 2>/dev/null \
       && ! gh auth status >/dev/null 2>&1; then
    jq -nc --arg e "$(tail -c 300 "$GH_LOGIN_OUT" 2>/dev/null)" '{state:"failed", error:$e}'
  elif gh auth status >/dev/null 2>&1; then
    jq -nc '{state:"done"}'
  else
    jq -nc '{state:"idle"}'
  fi
}

cmd_github_login() {
  local sub="${1:-status}"
  command -v gh >/dev/null 2>&1 || { echo '{"state":"failed","error":"gh is not installed. Run: brew install gh"}'; return 1; }
  goblin_ensure_dirs
  case "$sub" in
    start)
      if gh_login_running; then gh_login_state; return 0; fi
      : > "$GH_LOGIN_OUT"
      # The newline answers "Press Enter to open github.com in your browser".
      ( printf '\n'; sleep 900 ) | nohup gh auth login --hostname github.com --git-protocol https --web \
        > "$GH_LOGIN_OUT" 2>&1 &
      echo $! > "$GH_LOGIN_PID"
      local i=0
      while [ "$i" -lt 40 ] && [ -z "$(gh_login_code)" ] && gh_login_running; do sleep 0.2; i=$((i + 1)); done
      gh_login_state ;;
    status) gh_login_state ;;
    cancel)
      gh_login_running && kill "$(cat "$GH_LOGIN_PID")" 2>/dev/null
      rm -f "$GH_LOGIN_PID" "$GH_LOGIN_OUT"; echo '{"state":"idle"}' ;;
    *) echo "usage: goblin github-login [start|status|cancel]" >&2; return 2 ;;
  esac
}
