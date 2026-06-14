#!/usr/bin/env bash
# health-check.sh — Periodic health probe for Dev Studio
#
# Runs via systemd timer (every 30 min). Checks:
#   - Agent heartbeat files (stale if > 60 min old)
#   - Disk space (warn > 80%, error > 90%)
#   - Memory pressure (warn > 85%)
#   - Network reachability to api.github.com
#   - Critical processes (Claude Code, tmux sessions)
#
# Sends Telegram notification only if a threshold is breached.
# Quiet success (no spam on healthy runs).

set -uo pipefail

# Load env
[ -f "$HOME/.dev-studio-env" ] && source "$HOME/.dev-studio-env"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="${SCRIPT_DIR}/notify.sh"
# Per-project default (ADR-0010): infer project name from script location's repo root.
_HC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HC_PROJECT_DEFAULT="$(basename "$(cd "$_HC_SCRIPT_DIR/.." && pwd)")"
_HC_HEARTBEAT_BASE="${DEV_STUDIO_HEARTBEAT_BASE:-/var/log/dev-studio}"
HEARTBEAT_DIR="${DEV_STUDIO_HEARTBEAT_DIR:-$_HC_HEARTBEAT_BASE/$_HC_PROJECT_DEFAULT}"
HOSTNAME_TAG="$(hostname)"

# Thresholds
STALE_MINUTES=60
DISK_WARN=80
DISK_ERROR=90
MEM_WARN=85

# Accumulate findings
ALERTS=()
WARNINGS=()

add_alert()   { ALERTS+=("$1"); }
add_warning() { WARNINGS+=("$1"); }

# 1) Agent heartbeats
AGENTS=(orchestrator product-manager architect developer tester)
if [ -d "$HEARTBEAT_DIR" ]; then
  for agent in "${AGENTS[@]}"; do
    HB="$HEARTBEAT_DIR/${agent}.heartbeat"
    if [ ! -f "$HB" ]; then
      add_warning "Heartbeat missing: $agent (no file yet — agent may not have started)"
      continue
    fi
    AGE_SEC=$(( $(date +%s) - $(stat -c %Y "$HB") ))
    AGE_MIN=$(( AGE_SEC / 60 ))
    if [ "$AGE_MIN" -gt "$STALE_MINUTES" ]; then
      add_alert "STALE agent: $agent (last beat ${AGE_MIN} min ago)"
    fi
  done
else
  add_warning "Heartbeat dir missing: $HEARTBEAT_DIR"
fi

# 2) Disk space (root fs)
DISK_PCT=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "$DISK_PCT" -ge "$DISK_ERROR" ]; then
  add_alert "Disk usage critical: ${DISK_PCT}% on /"
elif [ "$DISK_PCT" -ge "$DISK_WARN" ]; then
  add_warning "Disk usage high: ${DISK_PCT}% on /"
fi

# 3) Memory pressure
MEM_PCT=$(free | awk '/^Mem:/ { printf "%.0f", ($3/$2)*100 }')
if [ "$MEM_PCT" -ge "$MEM_WARN" ]; then
  add_warning "Memory usage high: ${MEM_PCT}%"
fi

# 4) Network — GitHub reachability
if ! curl -sf --max-time 5 -o /dev/null https://api.github.com/zen; then
  add_alert "GitHub API unreachable from VM"
fi

# 5) Tmux sessions (optional — only warn if explicitly expected)
# Adım 15'te tmux session yönetimi eklenecek; şimdilik sadece bilgi
TMUX_COUNT=$(tmux ls 2>/dev/null | wc -l)

# Decision: alert > warning > silent
if [ "${#ALERTS[@]}" -gt 0 ]; then
  MSG="Health check ALERT on ${HOSTNAME_TAG}:"
  for a in "${ALERTS[@]}"; do MSG+=$'\n• '"$a"; done
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    MSG+=$'\n\nWarnings:'
    for w in "${WARNINGS[@]}"; do MSG+=$'\n• '"$w"; done
  fi
  MSG+=$'\n\nDisk: '"${DISK_PCT}"$'%  Mem: '"${MEM_PCT}"$'%  Tmux: '"${TMUX_COUNT}"
  "$NOTIFY" -l error "$MSG"
  exit 1
elif [ "${#WARNINGS[@]}" -gt 0 ]; then
  MSG="Health check warnings on ${HOSTNAME_TAG}:"
  for w in "${WARNINGS[@]}"; do MSG+=$'\n• '"$w"; done
  MSG+=$'\n\nDisk: '"${DISK_PCT}"$'%  Mem: '"${MEM_PCT}"$'%  Tmux: '"${TMUX_COUNT}"
  "$NOTIFY" -l warn "$MSG"
  exit 0
else
  # Silent success
  echo "[$(date -Iseconds)] All systems nominal. Disk=${DISK_PCT}% Mem=${MEM_PCT}% Tmux=${TMUX_COUNT}"
  exit 0
fi
