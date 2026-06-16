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
# Stuck-pane / API-overflow detection (new in stuck-pane fix).
STUCK_AFTER_MIN="${STUCK_AFTER_MIN:-20}"
# When the agent is pinned at CRITICAL_PCT (100%), use a much tighter window:
# /compact normally takes 30-90s; if pct hasn't moved in this many minutes,
# /compact has failed and /clear is the only escape hatch.
STUCK_AFTER_MIN_CRITICAL="${STUCK_AFTER_MIN_CRITICAL:-3}"
ESCALATE_STUCK_TO_CLEAR="${ESCALATE_STUCK_TO_CLEAR:-1}"

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
    '.[$role] // {last_reprime_utc:"", last_critical_seen_utc:"", last_pct:0, last_pct_change_utc:""}' \
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

# Detect Claude Code API overflow errors (context window exceeded). When seen,
# /compact CANNOT recover — only /clear works. Sample errors:
#   "API Error: 400 invalid params, context window exceeds limit"
#   "context_length_exceeded"
#   "prompt is too long"
agent_api_overflow() {
  local pane_idx="$1"
  local cap
  cap=$(tmux capture-pane -t "${TMUX_SESSION}:${TMUX_WINDOW}.${pane_idx}" -p -S -20 2>/dev/null || true)
  echo "$cap" | grep -qE '(context window exceeds limit|context_length_exceeded|prompt is too long|API Error: 400 invalid params)'
}

# A pane is considered STUCK (frozen showing stale "Worked for Ns") when:
#   (now - last_reprime_utc) >= threshold AND
#   last_pct_change_utc <= last_reprime_utc (pct hasn't moved since last reprime).
# Threshold depends on pct:
#   - pct >= CRITICAL_PCT (100%): STUCK_AFTER_MIN_CRITICAL (default 3min).
#     /compact normally takes 30-90s; if pct hasn't moved in 3min, /compact has
#     failed and only /clear can break the deadlock.
#   - pct < CRITICAL_PCT but >= THRESHOLD_PCT: STUCK_AFTER_MIN (default 20min).
#     Tolerate slower progress at lower context pressure.
# In that case the busy_skip check is bypassed and we force a reprime — optionally /clear.
agent_likely_stuck() {
  local role="$1" last_reprime_utc="$2" pct="$3"
  [ -z "$last_reprime_utc" ] && return 1
  local last_reprime_epoch
  last_reprime_epoch=$(iso_to_epoch "$last_reprime_utc")
  [ "$last_reprime_epoch" -eq 0 ] && return 1
  local threshold_min="$STUCK_AFTER_MIN"
  if [ "$pct" -ge "$CRITICAL_PCT" ]; then
    threshold_min="$STUCK_AFTER_MIN_CRITICAL"
  fi
  local stuck_sec=$((threshold_min * 60))
  local age=$((NOW_EPOCH - last_reprime_epoch))
  [ "$age" -lt "$stuck_sec" ] && return 1
  # Check if pct has changed since the last reprime.
  local cur_state pct_change_utc pct_change_epoch
  cur_state="$(state_for_role "$role")"
  pct_change_utc=$(echo "$cur_state" | jq -r '.last_pct_change_utc // ""')
  pct_change_epoch=$(iso_to_epoch "$pct_change_utc")
  # If pct changed AFTER last reprime, agent is making progress — not stuck.
  if [ "$pct_change_epoch" -gt "$last_reprime_epoch" ]; then
    return 1
  fi
  return 0
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
  prev_pct=$(echo "$state" | jq -r '.last_pct // 0')
  prev_pct_ts=$(echo "$state" | jq -r '.last_pct_ts // ""')

  # Always record the latest pct snapshot.
  # last_pct_change_utc is stamped ONLY when:
  #   (a) we have a prior observation (prev_pct_ts is non-empty) AND
  #   (b) the new pct differs from the prior pct.
  # This avoids false-stamping on the very first cycle (where prev_pct defaults
  # to 0 vs real pct=100), which would otherwise mask a frozen pane as "changed".
  if [ -n "$prev_pct_ts" ] && [ "$pct" != "$prev_pct" ]; then
    state_update "$role" "$(jq -cn --argjson p "$pct" --arg ts "$NOW_UTC" \
      '{last_pct:$p, last_pct_ts:$ts, last_pct_change_utc:$ts}')"
  else
    state_update "$role" "$(jq -cn --argjson p "$pct" --arg ts "$NOW_UTC" \
      '{last_pct:$p, last_pct_ts:$ts}')"
  fi

  if [ "$pct" -lt "$THRESHOLD_PCT" ]; then
    # Below threshold: clear sustained-critical marker if any.
    if [ -n "$last_critical_utc" ] && [ "$pct" -lt "$CRITICAL_PCT" ]; then
      state_update "$role" '{"last_critical_seen_utc":""}'
    fi
    log "${role}: ${pct}% (OK)"
    continue
  fi

  # >= threshold. Check busy state, BUT with stuck-pane / API-overflow override.
  use_clear=0
  if agent_api_overflow "$pane_idx"; then
    log "${role}: ${pct}% (API overflow detected — will force /clear)"
    "$JOURNAL_SH" append context_alert "$role" "watchdog" "api_overflow" "$pct" >/dev/null 2>&1 || true
    use_clear=1
  elif agent_is_busy "$pane_idx"; then
    if agent_likely_stuck "$role" "$last_reprime_utc" "$pct"; then
      stuck_window="$STUCK_AFTER_MIN"
      [ "$pct" -ge "$CRITICAL_PCT" ] && stuck_window="$STUCK_AFTER_MIN_CRITICAL"
      log "${role}: ${pct}% (busy AND stuck >${stuck_window}m — override; will force /clear)"
      "$JOURNAL_SH" append context_alert "$role" "watchdog" "stuck_override" "$pct" >/dev/null 2>&1 || true
      if [ "$ESCALATE_STUCK_TO_CLEAR" = "1" ]; then
        use_clear=1
      fi
    else
      log "${role}: ${pct}% (busy — skip; will retry next cycle)"
      "$JOURNAL_SH" append context_alert "$role" "watchdog" "busy_skip" "$pct" >/dev/null 2>&1 || true
      continue
    fi
  fi

  # Check cooldown.
  last_reprime_epoch=$(iso_to_epoch "$last_reprime_utc")
  cooldown_sec=$((COOLDOWN_MIN * 60))
  age=$((NOW_EPOCH - last_reprime_epoch))

  # Cooldown is bypassed when we've decided to force a hard /clear (use_clear=1).
  # Stuck panes and API-overflow are pathological states — waiting another
  # cooldown window just keeps the agent dead longer.
  if [ "$age" -lt "$cooldown_sec" ] && [ "$use_clear" != "1" ]; then
    log "${role}: ${pct}% (cooldown ${age}s/${cooldown_sec}s)"
    "$JOURNAL_SH" append context_alert "$role" "watchdog" "cooldown_skip" "$pct" >/dev/null 2>&1 || true
    # Still consider Telegram notify if critical sustained.
  else
    if [ "$use_clear" = "1" ] && [ "$age" -lt "$cooldown_sec" ]; then
      log "${role}: ${pct}% (cooldown ${age}s/${cooldown_sec}s BYPASSED — use_clear=1)"
      "$JOURNAL_SH" append context_alert "$role" "watchdog" "cooldown_bypass" "$pct" >/dev/null 2>&1 || true
    fi
    # Fire reprime.
    if [ "$DRY_RUN" = "1" ]; then
      log "${role}: ${pct}% (DRY_RUN — would reprime)"
    else
      log "${role}: ${pct}% (>= ${THRESHOLD_PCT}% — firing reprime)"
      "$JOURNAL_SH" append context_alert "$role" "watchdog" "context_pct_before" "$pct" >/dev/null 2>&1 || true
      reprime_env=""
      if [ "$use_clear" = "1" ]; then
        reprime_env="REPRIME_USE_CLEAR=1"
        log "${role}: passing REPRIME_USE_CLEAR=1 (hard /clear)"
      fi
      if env $reprime_env "$REPRIME_SH" "$role" >/dev/null 2>&1; then
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
