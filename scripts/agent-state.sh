#!/usr/bin/env bash
# agent-state.sh — per-agent state file helper (read/write/init).
#
# State files live at $AGENT_STATE_DIR/<role>.json (default /var/log/dev-studio/agent-state/).
# Each file holds:
#   {
#     "role": "<role>",
#     "last_seen_utc": "2026-06-10T15:00:00Z",
#     "processed_event_ids": ["evt-abc", "evt-def"],
#     "poll_interval_sec": 60,
#     "burst_until_utc": null
#   }
#
# Usage:
#   agent-state.sh init <role>           # create file if missing
#   agent-state.sh get <role> <key>      # echo a field
#   agent-state.sh set <role> <key> <value>
#   agent-state.sh seen <role> <event_id>  # check if event already processed
#   agent-state.sh mark <role> <event_id>  # mark event as processed (append + bump last_seen)
#   agent-state.sh path <role>           # echo the file path
#
# Requires: jq. Bails out cleanly if jq is missing.

set -euo pipefail

STATE_DIR="${AGENT_STATE_DIR:-/var/log/dev-studio/agent-state}"
DEFAULT_POLL="${AGENT_POLL_INTERVAL_SEC:-60}"

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
      # Need sudo? Bail with hint.
      echo "ERROR: cannot create $STATE_DIR. Run once as setup:" >&2
      echo "  sudo mkdir -p $STATE_DIR && sudo chown \$USER:\$USER $STATE_DIR" >&2
      exit 1
    }
  fi
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
         processed_event_ids: [],
         poll_interval_sec: $poll,
         burst_until_utc: null
       }' > "$file"
    echo "Initialised state: $file"
  else
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
  local tmp
  tmp="$(mktemp)"
  jq --arg v "$value" ".${key} = \$v" "$file" > "$tmp" && mv "$tmp" "$file"
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
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$event_id" --arg now "$now" '
    .processed_event_ids = (.processed_event_ids + [$id] | unique) |
    .last_seen_utc = $now
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

cmd_path() {
  state_path "$1"
}

# --- dispatch ---
case "${1:-}" in
  init)  shift; cmd_init "$@" ;;
  get)   shift; cmd_get "$@" ;;
  set)   shift; cmd_set "$@" ;;
  seen)  shift; cmd_seen "$@" ;;
  mark)  shift; cmd_mark "$@" ;;
  path)  shift; cmd_path "$@" ;;
  *)
    cat <<'USAGE' >&2
Usage:
  agent-state.sh init <role>
  agent-state.sh get  <role> <key>
  agent-state.sh set  <role> <key> <value>
  agent-state.sh seen <role> <event_id>
  agent-state.sh mark <role> <event_id>
  agent-state.sh path <role>
USAGE
    exit 2
    ;;
esac
