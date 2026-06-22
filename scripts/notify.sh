#!/usr/bin/env bash
# notify.sh — Send notification to Telegram via Bot API (+ optional tmux wake)
#
# Usage:
#   ./notify.sh "Message text"
#   ./notify.sh -l info "Sprint 1 kicked off"
#   ./notify.sh -l warn "CI flaky on PR #42"
#   ./notify.sh -l error "P0 BLOCKER: Production down"
#   ./notify.sh -l info -w -r developer "PR #42 ready for review"
#
# Env vars required (load from ~/.dev-studio-env):
#   TELEGRAM_BOT_TOKEN — Bot API token from @BotFather
#   TELEGRAM_CHAT_ID   — Target chat ID (user or group)
#
# Flags:
#   -l <level>   info | warn | error | ok (default: info)
#   -w           wake target agent via tmux pane (ADR-0033 dual-channel)
#   -r <role>    target agent role when -w is set: orchestrator |
#                product-manager | architect | developer | tester
#   -h           show this help
#
# ADR-0033 (Issue #221): -w requires -r. If -w set without -r, exit 2.
# Backward compat: when -w is NOT set, behavior is unchanged (Telegram only).
# Template port: Issue #222.

set -euo pipefail

# Load env if not already in scope
[ -f "$HOME/.dev-studio-env" ] && source "$HOME/.dev-studio-env"

# Defaults
LEVEL="info"
WAKE=""
ROLE=""
HOSTNAME_TAG="$(hostname)"

# Parse flags
while getopts "l:wr:h" opt; do
  case "$opt" in
    l) LEVEL="$OPTARG" ;;
    w) WAKE="true" ;;
    r) ROLE="$OPTARG" ;;
    h) echo "Usage: $0 [-l info|warn|error] [-w -r <role>] \"message\""; exit 0 ;;
    *) echo "Unknown flag"; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

MSG="${1:-}"
if [ -z "$MSG" ]; then
  echo "ERROR: no message provided" >&2
  echo "Usage: $0 [-l info|warn|error] [-w -r <role>] \"message\"" >&2
  exit 2
fi

# ADR-0033: -w requires -r. If wake mode requested without a role, fail loud.
if [ -n "$WAKE" ] && [ -z "$ROLE" ]; then
  echo "ERROR: -w (wake) requires -r <role> (ADR-0033 dual-channel)" >&2
  echo "       roles: orchestrator | product-manager | architect | developer | tester" >&2
  exit 2
fi

# Validate env
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "ERROR: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set" >&2
  echo "Source ~/.dev-studio-env or set them manually" >&2
  exit 1
fi

# Pick emoji based on level
case "$LEVEL" in
  info)  ICON="ℹ️" ;;
  warn)  ICON="⚠️" ;;
  error) ICON="🚨" ;;
  ok)    ICON="✅" ;;
  *)     ICON="🤖" ;;
esac

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# Build message (Markdown V2 escaping is fussy; use plain text for safety)
FULL_MSG="${ICON} [${LEVEL^^}] ${HOSTNAME_TAG}
${TIMESTAMP}

${MSG}"

# POST to Telegram
RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${FULL_MSG}" \
  --data-urlencode "disable_web_page_preview=true")

# Check response
if echo "$RESPONSE" | grep -q '"ok":true'; then
  echo "Notification sent: [$LEVEL] $MSG"
  # ADR-0033 dual-channel: when -w is set, also inject wake prompt into
  # the target agent's tmux pane. Silent no-op if tmux missing / unknown role.
  if [ -n "$WAKE" ]; then
    SCRIPT_DIR_NOTIFY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    WAKE_PROMPT="🔔 INBOX (dual-channel wake, notify.sh -w -r ${ROLE}):
[FULL_MSG_BEGIN]
${FULL_MSG}
[FULL_MSG_END]

Lütfen pickup et."
    "$SCRIPT_DIR_NOTIFY/agent-wake.sh" "$ROLE" "$WAKE_PROMPT" 2>/dev/null || true
    echo "Wake injected: role=$ROLE"
  fi
  exit 0
else
  echo "ERROR: Telegram API rejected the message" >&2
  echo "$RESPONSE" >&2
  exit 1
fi
