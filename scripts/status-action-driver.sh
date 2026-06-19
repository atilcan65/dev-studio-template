#!/usr/bin/env bash
# status-action-driver.sh — Parse agent STATUS blocks and derive actionable
# notifications. Implements Sprint 1 ORCH proactive mode (Issue #45 in
# AtilCalculator; generalized for any project bootstrapped from
# dev-studio-template).
#
# Per Issue #45 AC + PM conservative rollout (P3 caveat):
#   Phase 1 (always on):
#     - Blockers: N (>=1) with one-liner mentioning P0/P1 → escalate to human
#   Phase 2 (flag-gated; default OFF in Sprint 1 dry-run):
#     - Active agents list >= 4 + open status:in-progress issues → idle-team ping
#     - Agent-state last_seen_utc > 4h with open assigned issues → queue-age ping
#
# This script is the parser + derivation engine. Wiring into the orchestrator's
# agent-watch.sh pickup loop is the orchestrator's coordination concern; this
# script is callable as a standalone CLI and is unit-tested independently.
#
# Usage:
#   status-action-driver.sh --from-stdin [--dry-run] [--enable-phase2]
#   status-action-driver.sh --status-file <path> [--dry-run] [--enable-phase2]
#   status-action-driver.sh --version
#
# Environment:
#   PROJECT_NAME     — owner/repo slug (default: derived from `git remote get-url origin`)
#   HEARTBEAT        — audit log path (default: /var/log/dev-studio/$PROJECT_NAME/orchestrator.heartbeat)
#
# Output (JSON to stdout):
#   {
#     "parsed": {
#       "sprint": "01 (day 5/14)",
#       "active_agents": ["developer", "tester"],
#       "blockers_count": 1,
#       "blockers_text": "P0 post-merge CI red (issue #55)",
#       "next_action": "...",
#       "heartbeat": "OK"
#     },
#     "derived_actions": [
#       { "kind": "blocker_escalation", "phase": 1, "target": "human",
#         "evidence": "Blockers: 1 P0 post-merge CI red (issue #55)",
#         "ping_text": "[ORCH→HUMAN] STATUS-derived: P0 blocker — ..." }
#     ],
#     "audit_log_path": "...",
#     "dry_run": true|false,
#     "phase2_enabled": true|false
#   }
#
# Exit codes:
#   0 — success (parsed cleanly, possibly zero actions)
#   2 — usage error
#   3 — status block not parseable (no STATUS header found)
#   4 — status block read failure (file not found / empty stdin)
#   5 — audit log write failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NOTIFY_SH="$SCRIPT_DIR/notify.sh"

# Derive PROJECT_NAME from git remote if not set
if [ -z "${PROJECT_NAME:-}" ]; then
  PROJECT_NAME="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's#^.*github\.com[:/]##; s#\.git$##' \
    | tr '/' '-' || echo 'unknown-project')"
fi

HEARTBEAT="${HEARTBEAT:-/var/log/dev-studio/${PROJECT_NAME}/orchestrator.heartbeat}"
PROJECT_URL="${PROJECT_URL:-https://github.com/$(echo "$PROJECT_NAME" | tr '-' '/')}"

# ---------- CLI parsing ----------
DRY_RUN=false
ENABLE_PHASE2=false
STATUS_SOURCE=""
MODE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --from-stdin)    MODE="stdin" ;;
    --status-file)   MODE="file"; STATUS_SOURCE="${2:-}"; shift ;;
    --dry-run)       DRY_RUN=true ;;
    --enable-phase2) ENABLE_PHASE2=true ;;
    --version)       echo "status-action-driver.sh 0.2.0 (dev-studio-template, generalized from AtilCalculator #45)"; exit 0 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown flag: $1" >&2
      echo "Usage: status-action-driver.sh --from-stdin|--status-file <path> [--dry-run] [--enable-phase2]" >&2
      exit 2
      ;;
  esac
  shift
done

if [ -z "$MODE" ]; then
  echo "ERROR: must specify --from-stdin or --status-file <path>" >&2
  exit 2
fi

# ---------- Read the STATUS block ----------
read_status_block() {
  if [ "$MODE" = "stdin" ]; then
    if [ -t 0 ]; then
      echo "ERROR: --from-stdin but no data on stdin" >&2
      exit 4
    fi
    cat
  else
    if [ -z "$STATUS_SOURCE" ]; then
      echo "ERROR: --status-file requires a path" >&2
      exit 2
    fi
    if [ ! -f "$STATUS_SOURCE" ]; then
      echo "ERROR: status file not found: $STATUS_SOURCE" >&2
      exit 4
    fi
    cat "$STATUS_SOURCE"
  fi
}

STATUS_TEXT="$(read_status_block || true)"
if [ -z "$STATUS_TEXT" ]; then
  echo "ERROR: empty status block" >&2
  exit 4
fi

if ! echo "$STATUS_TEXT" | grep -q "^STATUS$"; then
  echo "ERROR: status block missing required 'STATUS' header line" >&2
  exit 3
fi

# ---------- Parse fields ----------
# Each field line is "Field: value". Use awk for robust extraction.
parse_field() {
  # $1 = field name; emits value (after first ": ") or empty
  echo "$STATUS_TEXT" | awk -v f="$1" '
    $0 ~ "^"f":[[:space:]]" {
      sub("^"f":[[:space:]]*", "")
      print
      exit
    }
  '
}

PARSED_SPRINT="$(parse_field Sprint)"
PARSED_ACTIVE="$(parse_field "Active agents")"
PARSED_BLOCKERS="$(parse_field Blockers)"
PARSED_NEXT="$(parse_field "Next action")"
PARSED_HEARTBEAT="$(parse_field Heartbeat)"

# Count of blockers — first token of "Blockers:" line
BLOCKERS_COUNT=0
BLOCKERS_TEXT=""
if [ -n "$PARSED_BLOCKERS" ]; then
  BLOCKERS_COUNT="$(echo "$PARSED_BLOCKERS" | awk '{print $1}')"
  if ! [[ "$BLOCKERS_COUNT" =~ ^[0-9]+$ ]]; then
    BLOCKERS_COUNT=0  # malformed; treat as zero per "Blockers: 0 → fine" semantic
  fi
  BLOCKERS_TEXT="$(echo "$PARSED_BLOCKERS" | cut -d' ' -f2-)"
fi

# Active agents list (comma-separated → JSON array)
ACTIVE_JSON="[]"
if [ -n "$PARSED_ACTIVE" ]; then
  ACTIVE_JSON="$(echo "$PARSED_ACTIVE" | awk '
    BEGIN { ORS=""; print "[" }
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      n = split($0, parts, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
        if (parts[i] != "") {
          printf "%s\"%s\"", (sep++ > 0 ? "," : ""), parts[i]
        }
      }
    }
    END { print "]" }
  ')"
fi

# ---------- Derive actions ----------
ACTIONS_JSON="[]"
APPEND_ACTION() {
  # $1 = kind, $2 = phase (1|2), $3 = target, $4 = evidence, $5 = ping_text
  local entry
  entry="$(printf '{"kind":"%s","phase":%s,"target":"%s","evidence":%s,"ping_text":%s}' \
    "$1" "$2" "$3" \
    "$(printf '%s' "$4" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$5" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')")"
  if [ "$ACTIONS_JSON" = "[]" ]; then
    ACTIONS_JSON="[$entry]"
  else
    ACTIONS_JSON="${ACTIONS_JSON%]},$entry]"
  fi
}

# Phase 1: Blocker escalation (always on)
if [ "$BLOCKERS_COUNT" -ge 1 ]; then
  if echo "$BLOCKERS_TEXT" | grep -Eq '\bP[01]\b'; then
    SEVERITY="$(echo "$BLOCKERS_TEXT" | grep -Eo '\bP[01]\b' | head -1)"
    PING_TEXT="[ORCH→HUMAN] STATUS-derived: ${SEVERITY} blocker — ${BLOCKERS_TEXT}
${PROJECT_URL}
Detected from orchestrator STATUS block. Conservative trigger per Sprint 1 PM caveat."
    APPEND_ACTION "blocker_escalation" "1" "human" \
      "Blockers: ${BLOCKERS_COUNT} ${BLOCKERS_TEXT}" \
      "$PING_TEXT"
  fi
fi

# Phase 2: Idle-team detection (flag-gated; default off in Sprint 1 dry-run)
if [ "$ENABLE_PHASE2" = true ]; then
  ACTIVE_COUNT="$(echo "$PARSED_ACTIVE" | tr ',' '\n' | wc -l | tr -d ' ')"
  if [ "$ACTIVE_COUNT" -ge 4 ]; then
    # Check for open status:in-progress issues (gh CLI; fail-safe to 0 if gh unavailable)
    IN_PROGRESS_COUNT="$(gh issue list --state open --label 'status:in-progress' --json number --jq 'length' 2>/dev/null || echo 0)"
    if [ "${IN_PROGRESS_COUNT:-0}" -ge 1 ]; then
      PING_TEXT="[ORCH→ALL] STATUS-derived: idle team (${ACTIVE_COUNT} agents listed) + ${IN_PROGRESS_COUNT} in-progress issues
${PROJECT_URL}
Phase-2 trigger. Flag-gated; enable only after 1 sprint dry-run per PM caveat."
      APPEND_ACTION "idle_team_ping" "2" "all" \
        "Active agents: ${ACTIVE_COUNT} + open in-progress: ${IN_PROGRESS_COUNT}" \
        "$PING_TEXT"
    fi
  fi
fi

# ---------- Emit actions ----------
EMITTED=0
ACTIONS_COUNT="$(echo "$ACTIONS_JSON" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')"
if [ "$ACTIONS_COUNT" -gt 0 ]; then
  if [ "$DRY_RUN" = false ] && [ -x "$NOTIFY_SH" ]; then
    # Extract each action's ping_text via Python and emit via notify.sh
    echo "$ACTIONS_JSON" | python3 -c '
import json, subprocess, sys
for a in json.load(sys.stdin):
    target = a["target"]
    text = a["ping_text"]
    subprocess.run([sys.argv[1], "-l", ("warn" if target == "human" else "info"), text], check=False)
' "$NOTIFY_SH" || true
    EMITTED="$ACTIONS_COUNT"
  else
    # Dry-run: count but do not actually call notify.sh
    EMITTED=0
  fi
fi

# ---------- Audit log ----------
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "${TIMESTAMP} kind=status_derived dry_run=${DRY_RUN} phase2=${ENABLE_PHASE2} parsed_blockers=${BLOCKERS_COUNT} actions_derived=${ACTIONS_COUNT} actions_emitted=${EMITTED}"
} >> "$HEARTBEAT" 2>/dev/null || {
  echo "WARN: could not append audit log to $HEARTBEAT" >&2
}

# ---------- Final JSON output ----------
cat <<EOF
{
  "parsed": {
    "sprint": $(printf '%s' "$PARSED_SPRINT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
    "active_agents": $ACTIVE_JSON,
    "blockers_count": $BLOCKERS_COUNT,
    "blockers_text": $(printf '%s' "$BLOCKERS_TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
    "next_action": $(printf '%s' "$PARSED_NEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
    "heartbeat": $(printf '%s' "$PARSED_HEARTBEAT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
  },
  "derived_actions": $ACTIONS_JSON,
  "audit_log_path": $(printf '%s' "$HEARTBEAT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
  "dry_run": $DRY_RUN,
  "phase2_enabled": $ENABLE_PHASE2,
  "actions_derived": $ACTIONS_COUNT,
  "actions_emitted": $EMITTED
}
EOF
