#!/usr/bin/env bash
# event-log.sh — append-only event log helper for agent-watch.sh.
#
# Why this exists
# ----------------
# Per Issue #237 (atomic-write state recovery): when the state file's
# processed_event_ids is corrupted, we need a source-of-truth to rebuild
# from. The event log is that source: every event processed by the watcher
# is appended here BEFORE mark(), so even if mark() fails or is killed
# mid-write, the event ID is preserved in the log.
#
# Layout (matches STATE_DIR default):
#   $AGENT_EVENT_LOG_DIR/<role>.jsonl    (one JSON object per line, append-only)
#   default: /var/log/dev-studio/<project>/event-log/<role>.jsonl
#
# Usage:
#   source event-log.sh
#   event_log_append <role> <event_json>     # append a single event (atomic)
#   event_log_recent  <role> [N]             # echo last N events as JSON array
#   event_log_path    <role>                 # echo the log path
#   event_log_count   <role>                 # echo total event count
#
# The append uses atomic_write pattern (write-to-temp + fsync + mv) so a
# kill mid-write leaves the previous log intact.
#
# Requires: jq. Bails out cleanly if jq is missing.

set -euo pipefail

# Per-project default (mirrors agent-state.sh's _AS_SCRIPT_DIR inference).
_EL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_EL_PROJECT_DEFAULT="$(basename "$(cd "$_EL_SCRIPT_DIR/.." && pwd)")"
_EL_LOG_BASE="${DEV_STUDIO_HEARTBEAT_BASE:-/var/log/dev-studio}"
EVENT_LOG_DIR="${AGENT_EVENT_LOG_DIR:-$_EL_LOG_BASE/$_EL_PROJECT_DEFAULT/event-log}"

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required. Install with: sudo apt-get install -y jq" >&2
    exit 127
  fi
}

ensure_log_dir() {
  if [ ! -d "$EVENT_LOG_DIR" ]; then
    mkdir -p "$EVENT_LOG_DIR" 2>/dev/null || {
      echo "ERROR: cannot create $EVENT_LOG_DIR" >&2
      exit 1
    }
  fi
}

event_log_path() {
  local role="$1"
  echo "${EVENT_LOG_DIR}/${role}.jsonl"
}

# Append a single event (JSON object) to the role's log atomically.
# Usage: event_log_append <role> <event_json>
# The event_json must be a valid JSON object (use jq -c to compact it).
event_log_append() {
  require_jq
  local role="$1" event_json="$2"
  local log
  log="$(event_log_path "$role")"
  ensure_log_dir
  # If file doesn't exist, create with empty content
  if [ ! -f "$log" ]; then
    : > "$log"
  fi
  # Validate event_json is a JSON object before append
  if ! echo "$event_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "ERROR: event_log_append: event_json is not a JSON object" >&2
    return 1
  fi
  # Atomic append: write (existing + new) to tmp, fsync, mv
  local tmp
  tmp="$(mktemp "${log}.append.XXXXXX")"
  cat "$log" > "$tmp"
  echo "$event_json" | jq -c . >> "$tmp"
  sync "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$log"
}

# Echo last N events as a JSON array (default N=100).
# Usage: event_log_recent <role> [N]
event_log_recent() {
  require_jq
  local role="$1" n="${2:-100}"
  local log
  log="$(event_log_path "$role")"
  if [ ! -f "$log" ]; then
    echo "[]"
    return 0
  fi
  tail -n "$n" "$log" | jq -s '.'
}

# Echo total event count in the log.
event_log_count() {
  local role="$1"
  local log
  log="$(event_log_path "$role")"
  if [ ! -f "$log" ]; then
    echo "0"
    return 0
  fi
  wc -l < "$log" | tr -d ' '
}

# Standalone smoke test
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  case "${1:-}" in
    append) shift; event_log_append "$@" ;;
    recent) shift; event_log_recent "$@" ;;
    path)   shift; event_log_path "$@" ;;
    count)  shift; event_log_count "$@" ;;
    *)
      cat <<'USAGE' >&2
Usage:
  event-log.sh append <role> <event_json>
  event-log.sh recent <role> [N]
  event-log.sh path   <role>
  event-log.sh count  <role>
USAGE
      exit 2
      ;;
  esac
fi
