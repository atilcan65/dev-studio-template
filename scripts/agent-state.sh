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
EVENT_LOG_DIR="${AGENT_EVENT_LOG_DIR:-$_AS_HEARTBEAT_BASE/$_AS_PROJECT_DEFAULT/event-log}"
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

# Source atomic-write helper (Issue #237). Must happen before jq_inplace so
# jq_inplace can delegate. atomic_write_json guarantees no half-written state
# even if process is killed mid-write (write-to-temp + sync + atomic mv).
# shellcheck source=./atomic-write.sh
source "$_AS_SCRIPT_DIR/atomic-write.sh"

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

# Atomic in-place jq edit: now delegates to atomic_write_json (Issue #237 fix).
# Signature unchanged (file, jq_args...) so all 13 call sites in this script
# automatically inherit the atomic-write guarantee. The old naive impl
# (mktemp in /tmp + mv across filesystems) could leave the target empty or
# partially-written if the process was killed mid-write. The new impl uses
# same-directory temp + sync + atomic mv — observers always see either the
# old content or the new content, never a half-written state.
jq_inplace() {
  atomic_write_json "$@"
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
         polled_at_utc: null,
         last_synthetic_scan_utc: null,
         proactive_sweep_last_utc: null,
         last_is_alive_utc: null
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
    # v3 → v4 backfill (ADR-0017): last_synthetic_scan_utc for periodic_backlog_scan throttle
    if ! jq -e 'has("last_synthetic_scan_utc")' "$file" >/dev/null 2>&1; then
      jq_inplace "$file" '.last_synthetic_scan_utc = null'
    fi
    # v4 → v5 backfill (Issue #44): proactive_sweep_last_utc for query_proactive_sweep throttle
    if ! jq -e 'has("proactive_sweep_last_utc")' "$file" >/dev/null 2>&1; then
      jq_inplace "$file" '.proactive_sweep_last_utc = null'
    fi
    # v5 → v6 backfill (Issue #238 sub-task 2, PR #245): last_is_alive_utc for
    # synthetic is_alive heartbeat (5-min cadence, emitted by agent-watch.sh).
    if ! jq -e 'has("last_is_alive_utc")' "$file" >/dev/null 2>&1; then
      jq_inplace "$file" '.last_is_alive_utc = null'
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
  local ttl_buckets="${3:-}"  # ADR-0032 RCA-32: optional TTL filter (5min buckets; 288 = 24h)
  local file
  file="$(state_path "$role")"
  [ -f "$file" ] || { echo "ERROR: state file missing: $file" >&2; exit 2; }
  if [ -n "$ttl_buckets" ] && [ "$ttl_buckets" -gt 0 ] 2>/dev/null; then
    # ADR-0032 RCA-32 TTL-aware trim: drop entries whose bucket is older
    # than (current - ttl_buckets), THEN slice to last $max. This bounds
    # the dedup buffer to a 24h sliding window so historical events from
    # past stale-cc conditions don't accumulate (refs Issue #216 RCA-18).
    # Non-bucket IDs (wake_nudge, pr-merged, pr-review) are RETAINED via
    # the if/test() pattern — they're bounded by their own throttle.
    local current_bucket cutoff
    current_bucket=$(( $(date -u +%s) / 300 ))
    cutoff=$(( current_bucket - ttl_buckets ))
    jq_inplace "$file" --argjson max "$max" --argjson cutoff "$cutoff" '
      .processed_event_ids = (
        [ .processed_event_ids[] |
          if test("b[0-9]+$") then
            (capture("b(?<bucket>[0-9]+)$").bucket | tonumber) as $b |
            select($b >= $cutoff)
          else
            .  # wake_nudge / pr-merged / pr-review — retain
          end
        ] | .[-$max:]
      )
    '
  else
    # Legacy behavior: just slice the last $max entries
    jq_inplace "$file" --argjson max "$max" '
      .processed_event_ids = (.processed_event_ids | .[-$max:])
    '
  fi
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

# Issue #237 (atomic-write state recovery, Sprint 4 P1):
# Validate state file integrity. Detects three corruption modes:
#   1. Missing file
#   2. jq parse error (truncated/empty file from killed mid-write)
#   3. Schema mismatch (missing required keys, processed_event_ids empty)
#
# Exit codes:
#   0 = state file is valid
#   1 = file missing
#   2 = jq parse error
#   3 = length-0 processed_event_ids
#   4 = schema mismatch
cmd_validate() {
  require_jq
  local role="$1"
  local file
  file="$(state_path "$role")"
  if [ ! -f "$file" ]; then
    echo "VALIDATE FAIL (1: missing): $file" >&2
    return 1
  fi
  if ! jq -e '.' "$file" >/dev/null 2>&1; then
    echo "VALIDATE FAIL (2: jq parse error): $file" >&2
    return 2
  fi
  local len
  len="$(jq -r '.processed_event_ids | length // 0' "$file" 2>/dev/null || echo 0)"
  if [ "$len" -le 0 ]; then
    echo "VALIDATE FAIL (3: processed_event_ids empty): $file" >&2
    return 3
  fi
  if ! jq -e 'has("role") and has("processed_event_ids") and has("last_seen_utc")' "$file" >/dev/null 2>&1; then
    echo "VALIDATE FAIL (4: schema mismatch): $file" >&2
    return 4
  fi
  echo "VALIDATE OK: $file ($len events)"
  return 0
}

# Issue #237: rebuild processed_event_ids from event log when state is
# corrupted. The event log is an append-only JSONL file at
# $EVENT_LOG_DIR/<role>.jsonl written by agent-watch.sh (via event_log_append).
# Each line is a JSON object: {"id": "...", "kind": "...", "ts": "...", ...}.
#
# Rebuild strategy: dedupe all event IDs found in the log, replace
# processed_event_ids with that dedup'd list, preserve other fields via
# jq merge. If state file doesn't exist, init from scratch.
#
# Exit codes:
#   0 = rebuild successful
#   1 = no event log found
#   2 = event log empty
cmd_rebuild() {
  require_jq
  local role="$1"
  local file event_log
  file="$(state_path "$role")"
  event_log="${EVENT_LOG_DIR}/${role}.jsonl"
  if [ ! -f "$event_log" ]; then
    echo "REBUILD FAIL (1: no event log): $event_log" >&2
    return 1
  fi
  # Extract event IDs from log, dedupe, build JSON array
  local ids_json count
  ids_json="$(jq -r 'select(.id != null) | .id' "$event_log" 2>/dev/null \
              | awk '!seen[$0]++' \
              | jq -R . | jq -s 'unique')"
  count="$(echo "$ids_json" | jq 'length')"
  if [ "$count" -le 0 ]; then
    echo "REBUILD FAIL (2: event log empty): $event_log" >&2
    return 2
  fi
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  # Atomic write: build replacement content, write to tmp, mv
  local tmp
  tmp="$(mktemp "${file}.rebuild.XXXXXX")"
  if [ ! -f "$file" ]; then
    # No state file — fresh init
    jq -n \
      --arg role "$role" \
      --arg now "$now" \
      --argjson ids "$ids_json" \
      --argjson poll "$DEFAULT_POLL" \
      '{
         role: $role,
         last_seen_utc: $now,
         last_heartbeat_utc: $now,
         processed_event_ids: $ids,
         poll_interval_sec: $poll,
         burst_until_utc: null,
         pr_merged_last_seen_utc: null,
         pr_labeled_last_seen_utc: null,
         polled_at_utc: null,
         last_synthetic_scan_utc: null,
         proactive_sweep_last_utc: null,
         last_is_alive_utc: null
       }' > "$tmp"
  else
    # Existing state file — preserve other fields, replace processed_event_ids
    jq --arg now "$now" --argjson ids "$ids_json" \
      '.processed_event_ids = $ids | .last_seen_utc = $now' "$file" > "$tmp"
  fi
  sync "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
  echo "REBUILD OK: restored $count event IDs from $event_log to $file"
  return 0
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
  validate)   shift; cmd_validate "$@" ;;
  rebuild)    shift; cmd_rebuild "$@" ;;
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
  agent-state.sh validate  <role>                    (Issue #237: exit 0 if state OK, 1-4 if corrupt)
  agent-state.sh rebuild   <role>                    (Issue #237: restore processed_event_ids from event log)
USAGE
    exit 2
    ;;
esac
