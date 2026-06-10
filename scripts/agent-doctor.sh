#!/usr/bin/env bash
# agent-doctor.sh — one-command diagnosis for stuck agents (Event Model v2).
#
# Per ADR-0003: silent-failure must be impossible. This tool answers
# "why isn't <role> waking up?" in seconds, with no screenshot chain.
#
# Usage:
#   agent-doctor.sh                          # check all 5 roles, print health summary
#   agent-doctor.sh <role>                   # deep-dive one role
#   agent-doctor.sh <role> --kick <pattern>  # surgical dedup removal (e.g. --kick pr-review-26)
#   agent-doctor.sh --alert                  # cron-friendly: stale roles → Telegram warn, exit code
#
# Examples:
#   ./agent-doctor.sh                        # quick health board
#   ./agent-doctor.sh tester                 # why tester not waking?
#   ./agent-doctor.sh tester --kick pr-review-26
#   ./agent-doctor.sh --alert                # in cron: */5 * * * *
#
# Exit codes:
#   0  — all roles fresh (or single role healthy)
#   1  — at least one role stale (--alert mode)
#   2  — usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_HELPER="$SCRIPT_DIR/agent-state.sh"
NOTIFY="$SCRIPT_DIR/notify.sh"
STATE_DIR="${AGENT_STATE_DIR:-/var/log/dev-studio/agent-state}"
LOG_DIR="${AGENT_LOG_DIR:-/var/log/dev-studio}"
STALE_SEC="${AGENT_HEARTBEAT_STALE_SEC:-300}"

ROLES=(orchestrator product-manager architect developer tester)

# Colours (graceful on no-TTY)
if [ -t 1 ]; then
  G="\033[32m"; Y="\033[33m"; R="\033[31m"; B="\033[1m"; D="\033[0m"
else
  G=""; Y=""; R=""; B=""; D=""
fi

require_jq() {
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 127; }
}
require_jq

# --- repo detection (for cc:<role> checks) ---
REPO="${GITHUB_REPO:-}"
if [ -z "$REPO" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
fi

# --- per-role health check ---
# Prints one summary line. Returns 0 if fresh, 1 if stale.
role_health_line() {
  local role="$1"
  local state_file="${STATE_DIR}/${role}.json"
  local pid_file="${LOG_DIR}/${role}.watch.pid"

  if [ ! -f "$state_file" ]; then
    printf "  %-16s ${R}NO STATE${D}\n" "$role"
    return 1
  fi

  # PID alive?
  local pid pid_status=""
  if [ -f "$pid_file" ]; then
    pid="$(cat "$pid_file")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      pid_status="${G}pid=${pid}${D}"
    else
      pid_status="${R}pid=${pid} DEAD${D}"
    fi
  else
    pid_status="${Y}no pid file${D}"
  fi

  # Heartbeat age
  local hb hb_epoch now_epoch age
  hb="$(jq -r '.last_heartbeat_utc // .last_seen_utc // empty' "$state_file")"
  if [ -z "$hb" ]; then
    printf "  %-16s ${R}NO HEARTBEAT${D}  %s\n" "$role" "$pid_status"
    return 1
  fi
  hb_epoch="$(date -u -d "$hb" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date -u +%s)"
  age=$((now_epoch - hb_epoch))

  local age_str hb_colour
  if [ "$age" -lt 120 ]; then
    age_str="${age}s"; hb_colour="$G"
  elif [ "$age" -lt "$STALE_SEC" ]; then
    age_str="${age}s"; hb_colour="$Y"
  else
    age_str="${age}s STALE"; hb_colour="$R"
  fi

  # Dedup list size
  local dedup_count
  dedup_count="$(jq '.processed_event_ids | length' "$state_file")"

  # cc:<role> PR count
  local cc_count="?"
  if [ -n "$REPO" ]; then
    cc_count="$(gh pr list --repo "$REPO" --label "cc:${role}" --state open --json number --jq 'length' 2>/dev/null || echo "?")"
  fi

  printf "  %-16s %s  hb=${hb_colour}%s${D}  dedup=%-3s  cc=%-2s\n" \
    "$role" "$pid_status" "$age_str" "$dedup_count" "$cc_count"

  [ "$age" -lt "$STALE_SEC" ]
}

# --- deep dive ---
role_deep_dive() {
  local role="$1"
  local state_file="${STATE_DIR}/${role}.json"
  local watch_log="${LOG_DIR}/${role}.watch.log"

  echo ""
  printf "${B}=== %s — deep dive ===${D}\n" "$role"
  echo ""

  if [ ! -f "$state_file" ]; then
    echo "  ✗ no state file at $state_file"
    return 1
  fi

  echo "  State file: $state_file"
  jq . "$state_file" | sed 's/^/    /'
  echo ""

  # Last 5 poll outcomes
  if [ -f "$watch_log" ]; then
    echo "  Last 5 poll outcomes (from $watch_log):"
    tail -n 500 "$watch_log" \
      | jq -c 'select(.role) | {at: .polled_at_utc, n: (.new_events | length), ids: [.new_events[].id]}' 2>/dev/null \
      | tail -n 5 | sed 's/^/    /'
    echo ""
  fi

  # cc:<role> PRs
  if [ -n "$REPO" ]; then
    echo "  Open PRs with cc:${role}:"
    gh pr list --repo "$REPO" --label "cc:${role}" --state open \
      --json number,title,updatedAt,headRefOid,labels 2>/dev/null \
      | jq -r '.[] | "    #\(.number) sha=\(.headRefOid[:7]) updated=\(.updatedAt) — \(.title)"' || echo "    (none)"
    echo ""
  fi

  # Diagnosis hints
  echo "  Diagnosis hints:"
  local dedup_size
  dedup_size="$(jq '.processed_event_ids | length' "$state_file")"
  if [ "$dedup_size" -gt 40 ]; then
    echo "    • dedup list at $dedup_size entries — close to trim limit (50); consider lowering."
  fi

  # Find PRs whose head_sha + cc combination is already deduped
  if [ -n "$REPO" ]; then
    local cc_prs
    cc_prs="$(gh pr list --repo "$REPO" --label "cc:${role}" --state open \
      --json number,headRefOid 2>/dev/null || echo '[]')"
    echo "$cc_prs" | jq -r '.[] | "\(.number) \(.headRefOid[:7])"' | while read -r num sha; do
      [ -z "$num" ] && continue
      # Does processed list contain a pr-review entry matching this number+sha?
      if jq -e --arg n "$num" --arg s "$sha" \
        '.processed_event_ids | any(. as $id | $id | test("pr-(review|commit)-" + $n + "-" + $s))' \
        "$state_file" >/dev/null 2>&1; then
        echo "    • PR #${num} (sha ${sha}) already in dedup — agent will not re-wake until SHA changes or label flip."
        echo "      Unblock with:  $0 $role --kick pr-review-${num}"
        echo "      Or:            $0 $role --kick pr-commit-${num}-${sha}"
      fi
    done
  fi
  echo ""
}

# --- alert mode (cron-friendly) ---
alert_mode() {
  local stale_roles=()
  for role in "${ROLES[@]}"; do
    if ! "$STATE_HELPER" stale "$role" "$STALE_SEC" >/dev/null 2>&1; then
      stale_roles+=("$role")
    fi
  done

  if [ "${#stale_roles[@]}" -eq 0 ]; then
    exit 0
  fi

  local msg="🩺 agent-doctor: ${#stale_roles[@]} role(s) stale (no heartbeat >${STALE_SEC}s): ${stale_roles[*]}
Run on VM:  /opt/dev-studio/atilprojects/scripts/agent-doctor.sh ${stale_roles[0]}"

  if [ -x "$NOTIFY" ]; then
    "$NOTIFY" -l warn "$msg" >/dev/null 2>&1 || true
  fi
  echo "$msg" >&2
  exit 1
}

# --- main dispatch ---
if [ "${1:-}" = "--alert" ]; then
  alert_mode
fi

if [ $# -eq 0 ]; then
  printf "${B}agent-doctor — health check (stale threshold: ${STALE_SEC}s)${D}\n\n"
  any_stale=0
  for role in "${ROLES[@]}"; do
    role_health_line "$role" || any_stale=1
  done
  echo ""
  echo "  Tip: ./agent-doctor.sh <role>             — deep dive"
  echo "       ./agent-doctor.sh <role> --kick PAT  — surgical unblock"
  exit $any_stale
fi

ROLE="$1"
shift || true

# Validate role
case "$ROLE" in
  orchestrator|product-manager|architect|developer|tester) ;;
  *) echo "ERROR: unknown role '$ROLE'. Valid: ${ROLES[*]}" >&2; exit 2 ;;
esac

if [ "${1:-}" = "--kick" ]; then
  PATTERN="${2:-}"
  if [ -z "$PATTERN" ]; then
    echo "ERROR: --kick requires a pattern (e.g. --kick pr-review-26)" >&2
    exit 2
  fi
  "$STATE_HELPER" kick "$ROLE" "$PATTERN"
  echo ""
  echo "Next poll (~60s) should re-emit events for matching PRs."
  echo "Watch:  tail -f ${LOG_DIR}/${ROLE}.watch.log"
  exit 0
fi

role_deep_dive "$ROLE"
