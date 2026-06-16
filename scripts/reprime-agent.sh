#!/usr/bin/env bash
# reprime-agent.sh — Soft re-prime an agent with guaranteed compaction.
#
# WHAT'S NEW (v2 — Context Watchdog integration)
# ----------------------------------------------
# 1. Before sending the re-prime message, fire `/compact` slash command to
#    deterministically trigger Claude Code's conversation compaction. We no
#    longer rely on Claude Code's auto-compact heuristic, which proved to
#    stay at "100% context used" indefinitely under sustained load.
# 2. Re-prime message now instructs the agent to re-read `scripts/kickoff/<role>.txt.tmpl`
#    in addition to CLAUDE.md and role doc. Kickoff template (FIRST ACTION
#    doctrine) is normally only read at session start; if auto-compact dropped
#    it, the agent loses doctrine until next restart.
# 3. If a facts journal exists, attach a 6h role-scoped summary at the top
#    of the message so the agent wakes up with situational context.
#
# Soft, enqueued: the message goes into the agent's chat input queue. The
# agent finishes its current turn (and any larger in-flight work unit)
# before processing the re-prime. See docs/CONTEXT-HYGIENE.md § 5.
#
# Targeting strategy
# ------------------
# We address panes by their deterministic pane index in the tmux session,
# as defined by scripts/dev-studio-start.sh:
#
#     pane 0 = orchestrator
#     pane 1 = product-manager
#     pane 2 = architect
#     pane 3 = developer
#     pane 4 = tester
#     pane 5 = human (not a re-prime target)
#
# Usage
# -----
#   bash scripts/reprime-agent.sh <role>
#
# Env overrides
# -------------
#   TMUX_SESSION             default: dev-studio
#   TMUX_WINDOW              default: main
#   REPRIME_SKIP_COMPACT     set to 1 to skip the /compact pre-step
#   REPRIME_JOURNAL_HOURS    default: 6 (hours of journal summary to attach)
#
# Exit codes
# ----------
#   0 — message sent.
#   1 — bad role or usage error.
#   2 — tmux session/window/pane not found, or role doc not found.

set -euo pipefail

TMUX_SESSION="${TMUX_SESSION:-dev-studio}"
TMUX_WINDOW="${TMUX_WINDOW:-main}"
REPRIME_SKIP_COMPACT="${REPRIME_SKIP_COMPACT:-0}"
REPRIME_JOURNAL_HOURS="${REPRIME_JOURNAL_HOURS:-6}"

# Role → pane index map.
declare -A ROLE_PANE=(
  [orchestrator]=0
  [product-manager]=1
  [architect]=2
  [developer]=3
  [tester]=4
)

VALID_ROLES=(orchestrator product-manager architect developer tester)

usage() {
  echo "Usage: $0 <role>"
  echo "  role: ${VALID_ROLES[*]}"
  echo ""
  echo "Env overrides:"
  echo "  TMUX_SESSION             default: dev-studio"
  echo "  TMUX_WINDOW              default: main"
  echo "  REPRIME_SKIP_COMPACT     set 1 to skip /compact pre-step"
  echo "  REPRIME_JOURNAL_HOURS    default: 6"
  exit 1
}

[ $# -eq 1 ] || usage
ROLE="$1"

if [ -z "${ROLE_PANE[$ROLE]+x}" ]; then
  echo "ERROR: invalid role '$ROLE'"
  usage
fi
PANE_IDX="${ROLE_PANE[$ROLE]}"
TARGET="${TMUX_SESSION}:${TMUX_WINDOW}.${PANE_IDX}"

# Resolve role-doc path.
ROLE_DOC=""
for candidate in \
  ".claude/agents/${ROLE}.md" \
  "docs/roles/${ROLE}.md" \
  "docs/agents/${ROLE}.md"; do
  if [ -f "$candidate" ]; then
    ROLE_DOC="$candidate"
    break
  fi
done

if [ -z "$ROLE_DOC" ]; then
  echo "ERROR: role doc for '$ROLE' not found in known locations." >&2
  echo "  Tried: .claude/agents/${ROLE}.md, docs/roles/${ROLE}.md, docs/agents/${ROLE}.md" >&2
  echo "  Run from the repo root." >&2
  exit 2
fi

KICKOFF_TMPL="scripts/kickoff/${ROLE}.txt.tmpl"
if [ ! -f "$KICKOFF_TMPL" ]; then
  echo "WARN: kickoff template not found at $KICKOFF_TMPL — re-prime will skip that hint." >&2
  KICKOFF_TMPL=""
fi

# Validate tmux infra.
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo "ERROR: tmux session '$TMUX_SESSION' not found." >&2
  exit 2
fi
if ! tmux list-windows -t "$TMUX_SESSION" -F '#W' | grep -qx "$TMUX_WINDOW"; then
  echo "ERROR: tmux window '$TMUX_WINDOW' not found in session '$TMUX_SESSION'." >&2
  exit 2
fi
if ! tmux list-panes -t "${TMUX_SESSION}:${TMUX_WINDOW}" -F '#P' | grep -qx "$PANE_IDX"; then
  echo "ERROR: pane index ${PANE_IDX} (role '${ROLE}') not found." >&2
  exit 2
fi

# ── STEP 1: deterministic compaction ────────────────────────────────────────
if [ "$REPRIME_SKIP_COMPACT" != "1" ]; then
  echo "→ Sending /compact to ${TARGET} (deterministic compaction)"
  tmux send-keys -t "$TARGET" "/compact" Enter
  # /compact can take 30-90s; we don't block here, just give Claude a head start
  # before the re-prime message lands. Re-prime is itself soft-enqueued so the
  # agent processes /compact first regardless.
  sleep 3
fi

# ── STEP 2: build journal summary (if journal exists) ───────────────────────
JOURNAL_SCRIPT=""
for candidate in \
  "$(dirname "$0")/agent-journal.sh" \
  "./scripts/agent-journal.sh"; do
  if [ -x "$candidate" ]; then
    JOURNAL_SCRIPT="$candidate"
    break
  fi
done

JOURNAL_SUMMARY=""
if [ -n "$JOURNAL_SCRIPT" ]; then
  if SUMMARY_OUT="$("$JOURNAL_SCRIPT" summary "$ROLE" "$REPRIME_JOURNAL_HOURS" 2>/dev/null)"; then
    if [ -n "$SUMMARY_OUT" ]; then
      JOURNAL_SUMMARY="$SUMMARY_OUT"
    fi
  fi
fi

# ── STEP 3: build re-prime message ──────────────────────────────────────────
MESSAGE_HEAD="[REPRIME] Doctrine may have changed and/or your context was compacted. Before your next action:"

KICKOFF_LINE=""
if [ -n "$KICKOFF_TMPL" ]; then
  KICKOFF_LINE="
6. Re-read ${KICKOFF_TMPL} to refresh your FIRST ACTION doctrine
   (this template is normally only read at session start; compaction
   may have dropped it from your working memory)."
fi

JOURNAL_BLOCK=""
if [ -n "$JOURNAL_SUMMARY" ]; then
  JOURNAL_BLOCK="

── LAST ${REPRIME_JOURNAL_HOURS}H FACTS (system-recorded, not your own notes) ──
${JOURNAL_SUMMARY}
"
fi

MESSAGE="${MESSAGE_HEAD}
1. Finish any in-flight work unit (do not abandon partial work).
2. Re-read .claude/CLAUDE.md (project root) and ${ROLE_DOC}.
3. Discard any cached assumptions from this conversation about labels,
   PR state, or issue status. Re-query GitHub for the current ground
   truth before acting.
4. Acknowledge with: [REPRIME ACK] ${ROLE}: <one-line summary of any
   doctrine change noticed, or 'no change'>.
5. Resume normal duties under the refreshed doctrine.${KICKOFF_LINE}
${JOURNAL_BLOCK}"

# ── STEP 4: paste + submit ──────────────────────────────────────────────────
TMP_BUF="$(mktemp)"
trap 'rm -f "$TMP_BUF"' EXIT
printf '%s\n' "$MESSAGE" > "$TMP_BUF"

BUFFER_NAME="reprime-${ROLE}-$$"
tmux load-buffer -b "$BUFFER_NAME" "$TMP_BUF"
tmux paste-buffer -b "$BUFFER_NAME" -t "$TARGET" -p
tmux delete-buffer -b "$BUFFER_NAME"
tmux send-keys -t "$TARGET" Enter

# ── STEP 5: append to journal (if available) ────────────────────────────────
if [ -n "$JOURNAL_SCRIPT" ]; then
  "$JOURNAL_SCRIPT" append reprime "$ROLE" "manual-or-watchdog" \
    "compacted=$([ "$REPRIME_SKIP_COMPACT" = "1" ] && echo no || echo yes)" >/dev/null 2>&1 || true
fi

echo "✓ Sent re-prime to ${TARGET} (role: ${ROLE}, pane index: ${PANE_IDX})"
echo "  Role doc:       ${ROLE_DOC}"
[ -n "$KICKOFF_TMPL" ]      && echo "  Kickoff hint:   ${KICKOFF_TMPL}"
[ -n "$JOURNAL_SUMMARY" ]   && echo "  Journal:        ${REPRIME_JOURNAL_HOURS}h summary attached"
[ "$REPRIME_SKIP_COMPACT" = "1" ] && echo "  /compact:       SKIPPED (REPRIME_SKIP_COMPACT=1)" || echo "  /compact:       sent before message"
echo "  Watch for:      [REPRIME ACK] ${ROLE}: ..."
