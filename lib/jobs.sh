#!/usr/bin/env bash
# jobs.sh — manual reviews as first-class jobs.
#
# A scheduled run is a loop over a queue; a manual review ("review #2456") is one
# deliberate request that a person is waiting on. It needs what the loop never did:
# an identity (so the app can show it), a visible phase (so the wait is not a
# spinner), a way to cancel, and a result a human can look at BEFORE it is posted.
#
# Everything about a job lives in $JOBS_DIR/<id>/ :
#
#   job.json      the one file the app watches: ref, phase, timestamps, pid, result
#   cancel        exists once a cancel was requested
#   log.txt       the job's own output (detached jobs write here)
#   preview/      the review waiting for a decision (see engine_save_preview)
#   config.json   present only when the job overrides provider/model
#
# Phases, in order:
#   queued → fetching → reading → reviewing → ready      (preview mode stops here)
#                                           → posting → done
#   and the terminal side exits:  failed, skipped, cancelled
#
# `ready` means a finished review is sitting in preview/ waiting for `goblin post`.

GOBLIN_JOB_ID=""
GOBLIN_JOB_DIR=""

JOB_ACTIVE_PHASES="queued fetching reading reviewing posting"

job_dir_of() { printf '%s/%s' "$JOBS_DIR" "$1"; }

# Job ids appear in paths and argv, so they are generated here and validated
# everywhere else against this shape.
job_id_ok() { printf '%s' "$1" | grep -qE '^j[0-9]{10}-[0-9]{1,6}$'; }
job_new_id() { printf 'j%s-%s' "$(now_epoch)" "$((RANDOM % 90000 + 10000))"; }

# job_write <id> '<json patch>' — merge a patch into job.json, atomically.
job_write() {
  local id="$1" patch="$2" f; f="$(job_dir_of "$id")/job.json"
  [ -d "$(dirname "$f")" ] || return 1
  local cur; cur="$(cat "$f" 2>/dev/null)"
  printf '%s' "$cur" | jq -e . >/dev/null 2>&1 || cur='{}'
  printf '%s' "$cur" | jq --argjson p "$patch" --argjson at "$(now_epoch)" \
    '. + $p + {updatedAt:$at}' | atomic_write "$f"
}

job_get() { jq -r --arg k "$2" '.[$k] // empty' "$(job_dir_of "$1")/job.json" 2>/dev/null; }

# job_phase <phase> [extra-json-patch] — a no-op outside a job, so the engine can
# call it unconditionally and the scheduled path is exactly what it was.
job_phase() {
  [ -n "$GOBLIN_JOB_ID" ] || return 0
  local patch="${2:-}"; [ -z "$patch" ] && patch='{}'
  job_write "$GOBLIN_JOB_ID" "$(printf '%s' "$patch" | jq -c --arg p "$1" '. + {phase:$p}')"
}

job_cancel_requested() { [ -n "$GOBLIN_JOB_DIR" ] && [ -e "$GOBLIN_JOB_DIR/cancel" ]; }

# All descendants of a pid, deepest first, so a kill never orphans a model CLI.
job_tree() {
  local p="$1" c
  for c in $(pgrep -P "$p" 2>/dev/null); do job_tree "$c"; done
  printf '%s\n' "$p"
}

job_alive() {
  local pid="$1"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# A job whose process is gone but whose phase still says "working" was killed — by
# a reboot, a crash or a force quit. Say so, rather than showing a spinner forever.
job_reconcile() {
  local id="$1" ph pid
  ph="$(job_get "$id" phase)"
  case " $JOB_ACTIVE_PHASES " in *" $ph "*) ;; *) return 0 ;; esac
  pid="$(job_get "$id" pid)"
  # A job that has not started yet has no pid; give a just-spawned one a moment.
  if [ -z "$pid" ]; then
    local made; made="$(job_get "$id" createdAt)"
    [ $(( $(now_epoch) - ${made:-0} )) -gt 30 ] || return 0
  elif job_alive "$pid"; then
    return 0
  fi
  job_write "$id" '{"phase":"failed","error":"interrupted","errorDetail":"The review process stopped before it finished."}'
}

# jobs_list_json [limit] — newest first, reconciled.
jobs_list_json() {
  local limit="${1:-50}" d id out="[]"
  [ -d "$JOBS_DIR" ] || { printf '[]'; return 0; }
  for d in "$JOBS_DIR"/j*; do
    [ -f "$d/job.json" ] || continue
    id="$(basename "$d")"; job_id_ok "$id" || continue
    job_reconcile "$id"
  done
  jq -s --argjson n "$limit" 'sort_by(-(.createdAt // 0)) | .[0:$n]' "$JOBS_DIR"/j*/job.json 2>/dev/null || printf '[]'
}

# jobs_counts_json — cheap enough for every status write: no jq per job.
jobs_counts_json() {
  local active=0 ready=0 d ph pid
  for d in "$JOBS_DIR"/j*; do
    [ -f "$d/job.json" ] || continue
    ph="$(sed -n 's/.*"phase": *"\([a-z]*\)".*/\1/p' "$d/job.json" 2>/dev/null | head -1)"
    case " $JOB_ACTIVE_PHASES " in
      *" $ph "*)
        # A dead pid is not active work, whatever the file still claims.
        pid="$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$d/job.json" 2>/dev/null | head -1)"
        if [ -z "$pid" ] || job_alive "$pid"; then active=$((active + 1)); fi ;;
    esac
    [ "$ph" = "ready" ] && ready=$((ready + 1))
  done
  printf '{"active":%s,"ready":%s}' "$active" "$ready"
}

# Keep two weeks of finished jobs; never touch one that is still working or that
# holds a review nobody has decided on yet.
jobs_prune() {
  local d ph
  [ -d "$JOBS_DIR" ] || return 0
  for d in "$JOBS_DIR"/j*; do
    [ -d "$d" ] || continue
    [ -n "$(find "$d" -maxdepth 0 -mtime +14 2>/dev/null)" ] || continue
    ph="$(jq -r '.phase // ""' "$d/job.json" 2>/dev/null)"
    case " $JOB_ACTIVE_PHASES ready " in *" $ph "*) continue ;; esac
    rm -rf "$d"
  done
}

# --- concurrency ------------------------------------------------------------
# A slot is a directory holding the pid of whoever has it. Slots are how
# maxConcurrentJobs is enforced across independent processes with no daemon.

_lock_owner_dead() {
  local d="$1" p; p="$(cat "$d/pid" 2>/dev/null)"
  if [ -n "$p" ]; then job_alive "$p" || return 0; return 1; fi
  # mkdir and the pid write are two steps; only call a pid-less lock dead once it
  # has been that way long enough that its owner must have died between them.
  [ -n "$(find "$d" -maxdepth 0 -mmin +2 2>/dev/null)" ]
}

JOB_SLOT_HELD=""
job_slot_acquire() {
  local max d n
  max="$(cfg_get '.maxConcurrentJobs' 2)"; [ "${max:-0}" -ge 1 ] 2>/dev/null || max=2
  mkdir -p "$LOCKS_DIR" 2>/dev/null
  while :; do
    n=1
    while [ "$n" -le "$max" ]; do
      d="$LOCKS_DIR/slot-$n"
      if mkdir "$d" 2>/dev/null; then echo $$ > "$d/pid"; JOB_SLOT_HELD="$d"; return 0; fi
      if _lock_owner_dead "$d"; then rm -rf "$d"; continue 2; fi
      n=$((n + 1))
    done
    job_cancel_requested && return 1
    sleep 1
  done
}
job_slot_release() { [ -n "$JOB_SLOT_HELD" ] && rm -rf "$JOB_SLOT_HELD"; JOB_SLOT_HELD=""; }

# One review at a time per repo: the scratch clone is shared, and `reset --hard`
# under a model that is reading it would corrupt its answer. Different repos run
# side by side. The scheduler takes the same lock, so a manual review and a
# scheduled one on one repo queue rather than collide.
REPO_LOCK_HELD=""
repo_lock_acquire() {
  local key d waited=0 limit="${2:-1800}"
  key="$(printf '%s' "$1" | tr '/' '_' | tr -cd '[:alnum:]._-')"
  d="$LOCKS_DIR/repo-$key"
  mkdir -p "$LOCKS_DIR" 2>/dev/null
  while ! mkdir "$d" 2>/dev/null; do
    if _lock_owner_dead "$d"; then rm -rf "$d"; continue; fi
    job_cancel_requested && return 1
    [ "$waited" -ge "$limit" ] && return 1
    sleep 1; waited=$((waited + 1))
  done
  echo $$ > "$d/pid"; REPO_LOCK_HELD="$d"
}
repo_lock_release() { [ -n "$REPO_LOCK_HELD" ] && rm -rf "$REPO_LOCK_HELD"; REPO_LOCK_HELD=""; }
