#!/usr/bin/env bash
# agent-journal.sh — System-written facts journal (drift-safe).
#
# PHILOSOPHY
# ----------
# Agents do NOT write to this journal. Only the watcher, the context monitor,
# and this script's own helpers append entries. This is intentional:
#
# - Agents under context pressure misdiagnose situations (real cases observed).
# - Agent-written notes can reinforce wrong patterns across re-primes (drift).
# - A system-written journal is verifiable against GitHub state and tmux logs.
#
# Format: JSON Lines (one JSON object per line). One file per UTC day.
#
# Schema (every record):
#   ts     ISO-8601 UTC timestamp
#   type   event class: pr_event | issue_event | reprime | context_alert |
#          state_change | watcher_poll
#   role   target role (or "system" if no specific role)
#   ref    short reference (e.g. "PR#28", "Issue#19", "watchdog-trigger")
#   fact   field name (e.g. "label_change", "context_pct_before")
#   value  field value (string; numbers stored as strings for jq portability)
#
# Subcommands
# -----------
#   append <type> <role> <ref> <fact> [<value>]
#       Append a single fact record. Lock-protected (flock).
#
#   summary <role> [<hours>]
#       Emit a human-readable, role-scoped summary of last N hours.
#       Default hours: 24. Used by reprime-agent.sh.
#
#   rotate
#       No-op by design (filename is date-based, "rotation" is automatic).
#       Provided as a hook in case operators want to gzip old files.
#
#   path
#       Print the journal file path for today.
#
# Env
# ---
#   JOURNAL_DIR   default: /var/log/dev-studio/${PROJECT_NAME}/journal
#                 falls back to: $HOME/.dev-studio/journal
#   PROJECT_NAME  default: derived from $PWD (basename of git root)

set -euo pipefail

# ── path resolution ─────────────────────────────────────────────────────────
project_name() {
  if [ -n "${PROJECT_NAME:-}" ]; then
    echo "$PROJECT_NAME"
    return
  fi
  local root
  if root=$(git rev-parse --show-toplevel 2>/dev/null); then
    basename "$root"
  else
    basename "$PWD"
  fi
}

journal_dir() {
  if [ -n "${JOURNAL_DIR:-}" ]; then
    echo "$JOURNAL_DIR"
    return
  fi
  local proj
  proj="$(project_name)"
  local sys_dir="/var/log/dev-studio/${proj}/journal"
  if [ -d "/var/log/dev-studio/${proj}" ] && [ -w "/var/log/dev-studio/${proj}" 2>/dev/null ]; then
    echo "$sys_dir"
  elif mkdir -p "$sys_dir" 2>/dev/null; then
    echo "$sys_dir"
  else
    echo "$HOME/.dev-studio/${proj}/journal"
  fi
}

today_file() {
  local d
  d="$(journal_dir)"
  mkdir -p "$d"
  echo "${d}/facts-$(date -u +%Y-%m-%d).jsonl"
}

# ── append ──────────────────────────────────────────────────────────────────
cmd_append() {
  # append <type> <role> <ref> <fact> [<value>]
  local type="${1:?type required}"
  local role="${2:?role required}"
  local ref="${3:?ref required}"
  local fact="${4:?fact required}"
  local value="${5:-}"

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local f
  f="$(today_file)"

  # jq -cn ensures proper JSON escaping for arbitrary values.
  local line
  line=$(jq -cn \
    --arg ts "$ts" \
    --arg type "$type" \
    --arg role "$role" \
    --arg ref "$ref" \
    --arg fact "$fact" \
    --arg value "$value" \
    '{ts:$ts,type:$type,role:$role,ref:$ref,fact:$fact,value:$value}')

  # flock prevents interleaved writes from concurrent watcher/monitor processes.
  (
    flock -x 200
    printf '%s\n' "$line" >> "$f"
  ) 200>>"$f.lock"
}

# ── summary ─────────────────────────────────────────────────────────────────
# Produce a human-readable last-N-hours summary scoped to a role.
# Used as input to reprime-agent.sh so the woken agent has situational context.
cmd_summary() {
  local role="${1:?role required}"
  local hours="${2:-24}"

  local d
  d="$(journal_dir)"
  [ -d "$d" ] || { echo ""; return; }

  # Window: now − $hours
  local cutoff
  cutoff="$(date -u -d "${hours} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -v "-${hours}H" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || echo "1970-01-01T00:00:00Z")"

  # Read today + yesterday's files (covers any hours <=48).
  local files=()
  for offset in 0 1 2; do
    local day_file="${d}/facts-$(date -u -d "${offset} days ago" +%Y-%m-%d 2>/dev/null \
                                  || date -u -v "-${offset}d" +%Y-%m-%d 2>/dev/null).jsonl"
    [ -f "$day_file" ] && files+=("$day_file")
  done
  [ ${#files[@]} -eq 0 ] && { echo ""; return; }

  # Filter by role and time window, then group by type and emit bulletpoints.
  local filtered
  filtered=$(cat "${files[@]}" 2>/dev/null \
    | jq -c --arg role "$role" --arg cutoff "$cutoff" \
        'select(.ts >= $cutoff) | select(.role == $role or .role == "system")')

  [ -z "$filtered" ] && { echo ""; return; }

  # Counts
  local n_reprime n_pr n_issue n_context
  n_reprime=$(echo "$filtered" | jq -s '[.[] | select(.type=="reprime")] | length')
  n_pr=$(echo "$filtered" | jq -s '[.[] | select(.type=="pr_event")] | length')
  n_issue=$(echo "$filtered" | jq -s '[.[] | select(.type=="issue_event")] | length')
  n_context=$(echo "$filtered" | jq -s '[.[] | select(.type=="context_alert")] | length')

  # Distinct PR refs touched
  local prs
  prs=$(echo "$filtered" | jq -r 'select(.type=="pr_event") | .ref' | sort -u | tr '\n' ' ')

  # Last user instruction (if logged) — last 3 lines of context_alert+fact=user_msg
  local last_msg
  last_msg=$(echo "$filtered" \
    | jq -r 'select(.fact=="user_msg") | .value' \
    | tail -1)

  # Build human-readable block.
  {
    echo "- Reprimes: ${n_reprime} in last ${hours}h"
    echo "- PR events touched: ${n_pr}${prs:+ ($prs)}"
    echo "- Issue events: ${n_issue}"
    echo "- Context alerts (≥85%): ${n_context}"
    [ -n "$last_msg" ] && echo "- Last user instruction: ${last_msg}"
  }
}

cmd_path() { today_file; }
cmd_rotate() { :; }   # no-op; date-based filename rotates implicitly

# ── dispatch ────────────────────────────────────────────────────────────────
case "${1:-}" in
  append)  shift; cmd_append "$@" ;;
  summary) shift; cmd_summary "$@" ;;
  rotate)  shift; cmd_rotate ;;
  path)    shift; cmd_path ;;
  *)
    cat >&2 <<EOF
Usage:
  $0 append <type> <role> <ref> <fact> [<value>]
  $0 summary <role> [<hours>]
  $0 path
  $0 rotate
EOF
    exit 1 ;;
esac
