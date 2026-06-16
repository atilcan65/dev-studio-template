#!/usr/bin/env bash
# agent-context-monitor.sh — Watchdog for Claude Code agent context usage.
#
# WHAT IT DOES
# ------------
# Once per invocation:
# 1. Capture each agent pane's last 5 lines.
# 2. Parse "% context used" indicator.
# 3. If pct >= THRESHOLD and (now - last_reprime) > COOLDOWN: send /compact + reprime.
# 4. If pct >= CRITICAL and pct stayed there > CRITICAL_SUSTAIN_MIN: send Telegram notify.
# 5. Append all decisions to the facts journal.
#
# Invoked by systemd timer every 60s (one-shot per call).
#
# CONFIG (env, all optional)
# --------------------------
#   THRESHOLD_PCT              default: 85
#   CRITICAL_PCT               default: 100
#   CRITICAL_SUSTAIN_MIN       default: 5
#   COOLDOWN_MIN               default: 10
#   TMUX_SESSION               default: dev-studio
#   TMUX_WINDOW                default: main
#   PROJECT_NAME               default: derived from cwd (git root basename)
#   DRY_RUN                    set 1 to log decisions but not act
#   NOTIFY_SCRIPT              default: ./scripts/notify.sh (Telegram), optional
#
# STATE
# -----
#   ${STATE_DIR}/context-monitor.json
#       Per-role: { last_reprime_utc, last_critical_seen_utc, last_pct }
#
# EXIT
# ----
#   0 always (logged to stdout; systemd captures via journalctl)

set -euo pipefail

THRESHOLD_PCT="${THRESHOLD_PCT:-85}"
CRITICAL_PCT="${CRITICAL_PCT:-100}"
CRITICAL_SUSTAIN_MIN="${CRITICAL_SUSTAIN_MIN:-5}"
COOLDOWN_MIN="${COOLDOWN_MIN:-10}"
TMUX_SESSION="${TMUX_SESSION:-dev-studio}"
TMUX_WINDOW="${TMUX_WINDOW:-main}"
DRY_RUN="${DRY_RUN:-0}"

# Resolve project name.
PROJECT_NAME="${PROJECT_NAME:-}"
if [ -z "$PROJECT_NAME" ]; then
  if root=$(git rev-parse --show-toplevel 2>/dev/null); then
    PROJECT_NAME="$(basename "$root")"
  else
    PROJECT_NAME="$(basename "$PWD")"
  fi
fi

# Resolve helper script paths.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPRIME_SH="${SCRIPT_DIR}/reprime-agent.sh"
JOURNAL_SH="${SCRIPT_DIR}/agent-journal.sh"
NOTIFY_SH="${NOTIFY_SCRIPT:-${SCRIPT_DIR}/notify.sh}"

[ -x "$REPRIME_SH" ] || { echo "ERROR: reprime-agent.sh not executable at $REPRIME_SH" >&2; exit 1; }
[ -x "$JOURNAL_SH" ] || { echo "ERROR: agent-journal.sh not executable at $JOURNAL_SH" >&2; exit 1; }

# State directory.
STATE_DIR="/var/log/dev-studio/${PROJECT_NAME}/agent-state"
mkdir -p "$STATE_DIR" 2>/dev/null || STATE_DIR="$HOME/.dev-studio/${PROJECT_NAME}/agent-state"
mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/context-monitor.json"
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

# Role → pane index.
declare -A ROLE_PANE=(
  [orchestrator]=0
  [product-manager]=1
  [architect]=2
  [developer]=3
  [tester]=4
)
ROLES=(orchestrator product-manager architect developer tester)

NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date -u +%s)"

# Helpers --------------------------------------------------------------------

log() { printf '[%s] %s\n' "$NOW_UTC" "$*"; }

# Read state for a role; emit JSON object (defaults if missing).
state_for_role() {
  local role="$1"
  jq -c --arg role "$role" \
    '.[$role] // {last_reprime_utc:"", last_critical_seen_utc:"", last_pct:0}' \
    "$STATE_FILE"
}

# Update state for a role with a JSON patch object.
state_update() {
  local role="$1" patch="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg role "$role" --argjson patch "$patch" \
    '.[$role] = ((.[$role] // {}) + $patch)' "$STATE_FILE" > "$tmp" \
    && mv "$tmp" "$STATE_FILE"
}

# Convert ISO-8601 UTC to epoch (or 0 if empty/invalid).
iso_to_epoch() {
  local iso="$1"
  [ -z "$iso" ] && { echo 0; return; }
  date -u -d "$iso" +%s 2>/dev/null || echo 0
}

# Parse context % from pane capture. Returns 0 if no indicator found.
read_context_pct() {
  local pane_idx="$1"
  local cap
  cap=$(tmux capture-pane -t "${TMUX_SESSION}:${TMUX_WINDOW}.${pane_idx}" -p -S -10 2>/dev/null || true)
  [ -z "$cap" ] && { echo 0; return; }
  # Match patterns like "100% context used" or "  47% context used".
  echo "$cap" \
    | grep -oE '[0-9]+%[[:space:]]+context used' \
    | tail -1 \
    | grep -oE '^[0-9]+' \
    || echo 0
}

# Is the agent currently working (mid-turn)? We treat "Worked for", "Cogitated for",
# "Sautéed for", "Crunched for" (Claude Code progress phrases) within the last
# 5 lines as "busy" — we don't want to interrupt active reasoning.
agent_is_busy() {
  local pane_idx="$1"
  local cap
  cap=$(tmux capture-pane -t "${TMUX_SESSION}:${TMUX_WINDOW}.${pane_idx}" -p -S -5 2>/dev/null || true)
  echo "$cap" | grep -qE '(Worked for [0-9]+s|Cogitated for [0-9]+s|Sautéed for [0-9]+s|Crunched for [0-9]+s|Compacting conversation)'
}

# Main loop ------------------------------------------------------------------

if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  log "tmux session '$TMUX_SESSION' not found; nothing to monitor."
  exit 0
fi

for role in "${ROLES[@]}"; do
  pane_idx="${ROLE_PANE[$role]}"
  pct="$(read_context_pct "$pane_idx")"
  pct="${pct:-0}"

  state="$(state_for_role "$role")"
  last_reprime_utc=$(echo "$state" | jq -r '.last_reprime_utc // ""')
  last_critical_utc=$(echo "$state" | jq -r '.last_critical_seen_utc // ""')

  # Always record the latest pct snapshot.
  state_update "$role" "$(jq -cn --argjson p "$pct" --arg ts "$NOW_UTC" \
    '{last_pct:$p, last_pct_ts:$ts}')"

  if [ "$pct" -lt "$THRESHOLD_PCT" ]; then
    # Below threshold: clear sustained-critical marker if any.
    if [ -n "$last_critical_utc" ] && [ "$pct" -lt "$CRITICAL_PCT" ]; then
      state_update "$role" '{"last_critical_seen_utc":""}'
    fi
    log "${role}: ${pct}% (OK)"
    continue
  fi

  # ≥ threshold. Check busy state.
  if agent_is_busy "$pane_idx"; then
    log "${role}: ${pct}% (busy — skip; will retry next cycle)"
    "$JOURNAL_SH" append context_alert "$role" "watchdog" "busy_skip" "$pct" >/dev/null 2>&1 || true
    continue
  fi

  # Check cooldown.
  last_reprime_epoch=$(iso_to_epoch "$last_reprime_utc")
  cooldown_sec=$((COOLDOWN_MIN * 60))
  age=$((NOW_EPOCH - last_reprime_epoch))

  if [ "$age" -lt "$cooldown_sec" ]; then
    log "${role}: ${pct}% (cooldown ${age}s/${cooldown_sec}s)"
    "$JOURNAL_SH" append context_alert "$role" "watchdog" "cooldown_skip" "$pct" >/dev/null 2>&1 || true
    # Still consider Telegram notify if critical sustained.
  else
    # Fire reprime.
    if [ "$DRY_RUN" = "1" ]; then
      log "${role}: ${pct}% (DRY_RUN — would reprime)"
    else
      log "${role}: ${pct}% (>= ${THRESHOLD_PCT}% — firing reprime)"
      "$JOURNAL_SH" append context_alert "$role" "watchdog" "context_pct_before" "$pct" >/dev/null 2>&1 || true
      if "$REPRIME_SH" "$role" >/dev/null 2>&1; then
        state_update "$role" "$(jq -cn --arg ts "$NOW_UTC" '{last_reprime_utc:$ts}')"
        "$JOURNAL_SH" append reprime "$role" "watchdog" "fired" "ok" >/dev/null 2>&1 || true
      else
        log "${role}: reprime FAILED"
        "$JOURNAL_SH" append reprime "$role" "watchdog" "fired" "fail" >/dev/null 2>&1 || true
      fi
    fi
  fi

  # Critical sustained notify path.
  if [ "$pct" -ge "$CRITICAL_PCT" ]; then
    if [ -z "$last_critical_utc" ]; then
      state_update "$role" "$(jq -cn --arg ts "$NOW_UTC" '{last_critical_seen_utc:$ts}')"
    else
      crit_epoch=$(iso_to_epoch "$last_critical_utc")
      crit_age=$((NOW_EPOCH - crit_epoch))
      sustain_sec=$((CRITICAL_SUSTAIN_MIN * 60))
      if [ "$crit_age" -ge "$sustain_sec" ]; then
        if [ -x "$NOTIFY_SH" ] && [ "$DRY_RUN" != "1" ]; then
          "$NOTIFY_SH" -l warn "[${PROJECT_NAME}] ${role} at ${pct}% for ${crit_age}s despite reprime — manual restart may be needed" >/dev/null 2>&1 || true
          log "${role}: sustained critical → notified operator"
          # Reset marker so we don't spam (one notify per sustained window).
          state_update "$role" "$(jq -cn --arg ts "$NOW_UTC" '{last_critical_seen_utc:$ts}')"
        fi
      fi
    fi
  fi
done

exit 0
