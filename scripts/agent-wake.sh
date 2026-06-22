#!/usr/bin/env bash
# agent-wake.sh — Inject a wake-up prompt into a named agent's tmux pane.
#
# ADR-0033 Auto-Ping dual-channel doctrine (Issue #221, PR #223) requires that
# peer-agent pings reach both Telegram (human mirror, via notify.sh) AND the
# target agent's tmux pane (agent wake). This script is the second half of
# that dual-channel wiring.
#
# Template port: Issue #222. Reference impl: atilcan65/AtilCalculator commit
# ecbf21a (PR #239). All projects bootstrapped from this template ship with
# the dual-channel wake capability.
#
# Usage:
#   scripts/agent-wake.sh <role> "<message>"
#
# Where:
#   <role>     — agent role: orchestrator | product-manager | architect |
#                developer | tester (silent no-op for unknown roles)
#   <message>  — free-form text; backticks/$VAR preserved (literal mode)
#
# Exit codes:
#   0  — success or silent no-op (tmux missing, unknown role, no session)
#   2  — missing args (usage error)
#
# Env vars:
#   TMUX_SESSION  — tmux session name (default: dev-studio)
#
# Backward-compat:
#   Safe to call when tmux is not installed or no session is running.
#   Silent no-op so callers don't need to guard.

set -uo pipefail

TMUX_SESSION="${TMUX_SESSION:-dev-studio}"

ROLE="${1:-}"
MSG="${2:-}"

# --- T4: missing args → usage error, exit 2 ---
if [ -z "$ROLE" ] || [ -z "$MSG" ]; then
  echo "Usage: $0 <role> \"<message>\"" >&2
  echo "Roles: orchestrator | product-manager | architect | developer | tester" >&2
  exit 2
fi

# --- T2: no tmux → silent no-op ---
command -v tmux >/dev/null 2>&1 || exit 0
tmux has-session -t "$TMUX_SESSION" 2>/dev/null || exit 0

# Find pane by title (uppercase role). Fallback: deterministic index map
# matching dev-studio-start.sh layout (orchestrator=0, ..., tester=4).
role_upper="$(echo "$ROLE" | tr '[:lower:]' '[:upper:]')"

pane_id="$(tmux list-panes -t "$TMUX_SESSION" -F '#{pane_id} #{pane_title}' 2>/dev/null \
  | awk -v t="$role_upper" '$2 == t { print $1; exit }')"

# Fallback index map (matches dev-studio-start.sh layout)
if [ -z "$pane_id" ]; then
  case "$ROLE" in
    orchestrator)    pane_id="${TMUX_SESSION}:main.0" ;;
    product-manager) pane_id="${TMUX_SESSION}:main.1" ;;
    architect)       pane_id="${TMUX_SESSION}:main.2" ;;
    developer)       pane_id="${TMUX_SESSION}:main.3" ;;
    tester)          pane_id="${TMUX_SESSION}:main.4" ;;
    # --- T3: unknown role → silent no-op, exit 0 ---
    *) exit 0 ;;
  esac
fi

# T7: literal-mode (-l) so backticks and $VAR in the message survive intact.
tmux send-keys -t "$pane_id" -l "$MSG" 2>/dev/null || exit 0
tmux send-keys -t "$pane_id" Enter 2>/dev/null || true
