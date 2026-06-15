#!/usr/bin/env bash
# agent-state.sh — per-agent state file helper (read/write/init).
#
# State files live at $AGENT_STATE_DIR/<role>.json (default /var/log/dev-studio/agent-state/).
# Each file holds:
#   {
#     "role": "<role>",
#     "last_seen_utc": "2026-06-10T15:00:00Z",
#     "last_heartbeat_utc": "2026-06-10T15:00:00Z",
#     "processed_event_ids": ["evt-abc", "evt-def"],
#     "poll_interval_sec": 60,
#     "burst_until_utc": null,
#     "pr_merged_last_seen_utc": null,    # v3: high-water mark for PR merged events
#     "pr_labeled_last_seen_utc": null,   # v3: high-water mark for PR labeled events
#     "polled_at_utc": null               # v3: timestamp of most recent poll (set by watcher each cycle)
#   }
#
# Schema evolution: new optional fields default to null and are backfilled
# on next `init` call for any pre-existing state file (see cmd_init). This
# preserves backward compatibility — watchers / doctor scripts that already
# wrote these fields via `set` continue to work; fresh init now declares them
# upfront so consumers can rely on key existence.
#
# Usage:
#   agent-state.sh init <role>                   # create file if missing
#   agent-state.sh get <role> <key>              # echo a field
#   agent-state.sh set <role> <key> <value>      # set string field
#   agent-state.sh seen <role> <event_id>        # check if event already processed
#   agent-state.sh mark <role> <event_id>        # mark event as processed (append + bump last_seen)
#   agent-state.sh path <role>                   # echo the file path
#   agent-state.sh heartbeat <role>              # bump last_heartbeat_utc (called by watcher)
#   agent-state.sh trim <role> [max]             # trim processed_event_ids to last N (default 50)
#   agent-state.sh kick <role> <pattern>         # remove processed_event_ids matching glob (one-shot unblock)
#   agent-state.sh stale <role> [threshold_sec]  # exit 0 if heartbeat fresh, 1 if stale (default 300s)
#
# Requires: jq. Bails out cleanly if jq is missing.

set -euo pipefail

# Per-project default (ADR-0010): infer project name from script location's repo root.
# Allow explicit AGENT_STATE_DIR override (used by systemd unit env files).
_AS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_AS_PROJECT_DEFAULT="$(basename "$(cd "$_AS_SCRIPT_DIR/.." && pwd)")"
_AS_HEARTBEAT_BASE="${DEV_STUDIO_HEARTBEAT_BASE:-/var/log/dev-studio}"
STATE_DIR="${AGENT_STATE_DIR:-$_AS_HEARTBEAT_BASE/$_AS_PROJECT_DEFAULT/agent-state}"
DEFAULT_POLL="${AGENT_POLL_INTERVAL_SEC:-60}"
DEFAULT_TRIM_MAX="${AGENT_PROCESSED_MAX:-200}"
DEFAULT_STALE_SEC="${AGENT_HEARTBEAT_STALE_SEC:-300}"

# --- preflight ---
require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required. Install with: sudo apt-get install -y jq" >&2
    exit 127
  fi
}

state_path() {
  local role="$1"
  echo "${STATE_DIR}/${role}.json"
}

ensure_dir() {
  if [ ! -d "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || {
      echo "ERROR: cannot create $STATE_DIR. Run once as setup:" >&2
      echo "  sudo mkdir -p $STATE_DIR && sudo chown \$USER:\$USER $STATE_DIR" >&2
      exit 1
    }
  fi
}

# Atomic in-place jq edit: read file, apply filter, write to tmp, rename.
jq_inplace() {
  local file="$1"
  shift
  local tmp
  tmp="$(mktemp)"
  jq "$@" "$file" > "$tmp" && mv "$tmp" "$file"
}

cmd_init() {
  require_jq
  local role="$1"
  ensure_dir
  local file
  file="$(state_path "$role")"
  if [ ! -f "$file" ]; then
    local now
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    jq -n \
      --arg role "$role" \
      --arg now "$now" \
      --argjson poll "$DEFAULT_POLL" \
      '{
         role: $role,
         last_seen_utc: $now,
         last_heartbeat_utc: $now,
         processed_event_ids: [],
         poll_interval_sec: $poll,
         burst_until_utc: null,
         pr_merged_last_seen_utc: null,
         pr_labeled_last_seen_utc: null,
         polled_at_utc: null
       }' > "$file"
    echo "Initialised state: $file"
  else
    # Backfill missing fields. Pattern is idempotent: if the field already
    # exists (even with a non-null value) we don't touch it. This is how
    # the schema evolves without breaking pre-existing state files.
    #
    # v2 → v3 backfill: last_heartbeat_utc, pr_merged_last_seen_utc,
    # pr_labeled_last_seen_utc, polled_at_utc.
    local now
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if ! jq -e 'has("last_heartbeat_utc")' "$file" >/dev/null 2>&1; then
      jq_inplace "$file" --arg now "$now" '.last_heartbeat_utc = $now'
    fi
    if ! jq -e 'has("pr_merged_last_seen_utc")' "$file" >/dev/null 2>&1; then
      jq_inplace "$file" '.pr_merged_last_seen_utc = null'
    fi
    if ! jq -e 'has("pr_labeled_last_seen_utc")' "$file" >/dev/null 2>&1; then
      jq_inplace "$file" '.pr_labeled_last_seen_utc = null'
    fi
    if ! jq -e 'has("polled_at_utc")' "$file" >/dev/null 2>&1; then
      jq_inplace "$file" '.polled_at_utc = null'
    fi
    echo "State already exists: $file"
  fi
}

cmd_get() {
  require_jq
  local role="$1" key="$2"
  local file
  file="$(state_path "$role")"
  [ -f "$file" ] || { echo "ERROR: state file missing: $file" >&2; exit 2; }
  jq -r ".${key} // empty" "$file"
}

cmd_set() {
  require_jq
  local role="$1" key="$2" value="$3"
  local file
  file="$(state_path "$role")"
  [ -f "$file" ] || cmd_init "$role"
  # Use --arg for safety; numeric/bool callers must JSON-encode if needed.
  jq_inplace "$file" --arg v "$value" ".${key} = \$v"
}

cmd_seen() {
  require_jq
  local role="$1" event_id="$2"
  local file
  file="$(state_path "$role")"
  [ -f "$file" ] || { echo "false"; return; }
  if jq -e --arg id "$event_id" '.processed_event_ids | index($id) != null' "$file" >/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

cmd_mark() {
  require_jq
  local role="$1" event_id="$2"
  local file
  file="$(state_path "$role")"
  [ -f "$file" ] || cmd_init "$role"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  jq_inplace "$file" --arg id "$event_id" --arg now "$now" '
    .processed_event_ids = (.processed_event_ids + [$id] | unique) |
    .last_seen_utc = $now
  '
}

cmd_path() {
  state_path "$1"
}

# v2: bump heartbeat (separate from last_seen_utc which is event-driven).
# Heartbeat is poll-driven: proves the watcher loop is still alive even if
# no new events have arrived. agent-doctor.sh / cron compare this against
# now() and alert via notify.sh if a role goes silent.
cmd_heartbeat() {
  require_jq
  local role="$1"
  local file
  file="$(state_path "$role")"
  [ -f "$file" ] || cmd_init "$role" >/dev/null
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  jq_inplace "$file" --arg now "$now" '.last_heartbeat_utc = $now'
}

# v2: keep processed_event_ids bounded (FIFO trim to last N).
# Without this the array grows unbounded across months of runtime — JSON parse
# slows down, watcher RAM creeps. Default 200 (post issue-#61 fix, was 50)
# is generous backstop headroom so the dedup window survives a watcher's
# `LAST_SEEN` being momentarily stale (issue #61 Bug A: `LAST_SEEN` was frozen
# at script start; now refreshed on every poll). 200 covers ~hours of activity
# even at peak burst across all event families.
cmd_trim() {
  require_jq
  local role="$1"
  local max="${2:-$DEFAULT_TRIM_MAX}"
  local file
  file="$(state_path "$role")"
  [ -f "$file" ] || { echo "ERROR: state file missing: $file" >&2; exit 2; }
  jq_inplace "$file" --argjson max "$max" '
    .processed_event_ids = (.processed_event_ids | .[-$max:])
  '
}

# v2: surgical removal of dedup entries matching a substring (one-shot unblock).
# Use case: a single PR is wedged because processed_event_ids contains stale
# entries for it; kick removes only those, leaving other PRs' dedup intact.
#
# Example: agent-state.sh kick tester pr-review-26
#   → drops any processed id containing "pr-review-26"
cmd_kick() {
  require_jq
  local role="$1" pattern="$2"
  local file
  file="$(state_path "$role")"
  [ -f "$file" ] || { echo "ERROR: state file missing: $file" >&2; exit 2; }
  local before after
  before="$(jq '.processed_event_ids | length' "$file")"
  jq_inplace "$file" --arg pat "$pattern" '
    .processed_event_ids |= map(select(contains($pat) | not))
  '
  after="$(jq '.processed_event_ids | length' "$file")"
  echo "kicked: $((before - after)) entry/entries (pattern: $pattern)"
}

# v2: liveness check. Exit 0 if last_heartbeat_utc within threshold, 1 if stale.
# Used by cron / agent-doctor to alert when a watcher silently died.
cmd_stale() {
  require_jq
  local role="$1"
  local threshold="${2:-$DEFAULT_STALE_SEC}"
  local file
  file="$(state_path "$role")"
  [ -f "$file" ] || { echo "STALE (no state file)"; exit 1; }
  local hb
  hb="$(jq -r '.last_heartbeat_utc // empty' "$file")"
  if [ -z "$hb" ]; then
    echo "STALE (no heartbeat yet)"
    exit 1
  fi
  local hb_epoch now_epoch age
  hb_epoch="$(date -u -d "$hb" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date -u +%s)"
  age=$((now_epoch - hb_epoch))
  if [ "$age" -gt "$threshold" ]; then
    echo "STALE (heartbeat ${age}s ago, threshold ${threshold}s)"
    exit 1
  fi
  echo "FRESH (heartbeat ${age}s ago)"
  exit 0
}

# --- dispatch ---
case "${1:-}" in
  init)       shift; cmd_init "$@" ;;
  get)        shift; cmd_get "$@" ;;
  set)        shift; cmd_set "$@" ;;
  seen)       shift; cmd_seen "$@" ;;
  mark)       shift; cmd_mark "$@" ;;
  path)       shift; cmd_path "$@" ;;
  heartbeat)  shift; cmd_heartbeat "$@" ;;
  trim)       shift; cmd_trim "$@" ;;
  kick)       shift; cmd_kick "$@" ;;
  stale)      shift; cmd_stale "$@" ;;
  *)
    cat <<'USAGE' >&2
Usage:
  agent-state.sh init      <role>
  agent-state.sh get       <role> <key>
  agent-state.sh set       <role> <key> <value>
  agent-state.sh seen      <role> <event_id>
  agent-state.sh mark      <role> <event_id>
  agent-state.sh path      <role>
  agent-state.sh heartbeat <role>
  agent-state.sh trim      <role> [max]              (default max: 50)
  agent-state.sh kick      <role> <id_substring>     (drop dedup entries matching substring)
  agent-state.sh stale     <role> [threshold_sec]    (default: 300; exit 1 if stale)
USAGE
    exit 2
    ;;
esac
