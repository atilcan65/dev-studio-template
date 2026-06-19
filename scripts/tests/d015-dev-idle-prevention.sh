#!/usr/bin/env bash
# d015-dev-idle-prevention.sh — regression test for Dev-Idle Prevention (Katman 1+2).
#
# Katman 1: `poll_once` JSON output now includes `wake_nudge` field. When
# `agent:<role>` or `cc:<role>` is on open issues, wake_nudge emits even
# if `new_events` is empty. The nudge exposes the queue.
#
# Katman 2: `wake_pane_for_role` is now called with combined payload
# (events + nudges), so the agent wakes on nudge alone.
#
# Bug-class defended against:
#   1. wake_nudge field missing from poll_once JSON output (Katman 1 not applied)
#   2. wake_nudge field present but always empty (queue check broken)
#   3. wake_nudge emit JSON shape wrong → agent consumer breaks
#   4. wake_pane_for_role still uses only new_events (Katman 2 not applied)
#   5. wake_nudge computed unconditionally even when REPO unset (would crash)
#
# Test cases:
#   T1:  wake_nudge field emitted in poll_once JSON output
#   T2:  wake_nudge is `[]` when no agent:<role> or cc:<role> open issues
#   T3:  wake_nudge is non-empty array when agent:<role> open issues exist
#   T4:  wake_nudge is non-empty when cc:<role> open issues exist
#   T5:  wake_nudge event has expected kind="wake_nudge"
#   T6:  wake_nudge event has id format: wake-nudge-<role>-<ts>
#   T7:  wake_nudge event context includes agent_count + cc_count + note
#   T8:  Katman 2: wake_pane_for_role called with combined payload (events + nudges)
#   T9:  Wake nudge guarded by REPO env var (no crash if unset)
#
# Exit code: 0 = all pass, 1 = at least one fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH_SH="$SCRIPT_DIR/../agent-watch.sh"

# Colors (TTY-aware)
if [[ -t 1 ]]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; B=$'\033[1m'; D=$'\033[0m'
else
  G=""; R=""; B=""; D=""; fi

PASS=0; FAIL=0
pass() { printf "  ${G}✓ PASS${D} — %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  ${R}✗ FAIL${D} — %s\n" "$1"; [ -n "${2:-}" ] && printf "    ${R}%s\n" "$2"; FAIL=$((FAIL+1)); }
section() { printf "\n${B}==== %s ====${D}\n" "$1"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2; exit 127
fi
if [ ! -r "$WATCH_SH" ]; then
  echo "ERROR: agent-watch.sh not found at $WATCH_SH" >&2; exit 127
fi

# ============================================================================
# T1: wake_nudge field emitted in poll_once JSON output
# ============================================================================
section "T1: wake_nudge field in poll_once JSON emit"
if grep -Eq '^\s*--argjson nudge "\$wake_nudge"' "$WATCH_SH" && \
   grep -Eq '^\s*wake_nudge: \$nudge' "$WATCH_SH"; then
  pass "poll_once emits wake_nudge field in jq output"
else
  fail "wake_nudge not in emit jq" "expected --argjson nudge + wake_nudge: \$nudge in poll_once emit"
fi

# ============================================================================
# T2: wake_nudge initialized to empty array
# ============================================================================
section "T2: wake_nudge initialized to empty array"
if grep -Eq "local wake_nudge='\[\]'" "$WATCH_SH"; then
  pass "wake_nudge initialized to '[]' before queue check"
else
  fail "wake_nudge not initialized to empty array" "expected 'local wake_nudge=\"[]\"' or similar at start of computation"
fi

# ============================================================================
# T3: wake_nudge computed when agent:<role> open issues exist
# ============================================================================
section "T3: wake_nudge computed when agent:<role> label exists on open issues"
if grep -Fq 'label "agent:${ROLE}"' "$WATCH_SH"; then
  pass "queue check filters by agent:<role> label"
else
  fail "queue check missing" "expected gh call filtering by agent:\${ROLE} label"
fi

# ============================================================================
# T4: wake_nudge computed when cc:<role> open issues exist
# ============================================================================
section "T4: wake_nudge computed when cc:<role> label exists on open issues"
if grep -Fq 'label "cc:${ROLE}"' "$WATCH_SH"; then
  pass "cc queue check filters by cc:<role> label"
else
  fail "cc queue check missing" "expected gh call filtering by cc:\${ROLE} label"
fi

# ============================================================================
# T5: wake_nudge event kind = "wake_nudge"
# ============================================================================
section "T5: wake_nudge event has kind: wake_nudge"
if grep -Fq 'kind: "wake_nudge"' "$WATCH_SH"; then
  pass "wake_nudge events have kind field set to 'wake_nudge'"
else
  fail "wake_nudge event kind wrong" "expected 'kind: \"wake_nudge\"' in jq emit"
fi

# ============================================================================
# T6: wake_nudge event id format
# ============================================================================
section "T6: wake_nudge event id format: wake-nudge-<role>-<ts>"
if grep -Fq 'wake-nudge-' "$WATCH_SH"; then
  pass "wake_nudge event id uses wake-nudge- prefix"
else
  fail "wake_nudge event id format missing" "expected 'wake-nudge-' prefix in event id"
fi

# ============================================================================
# T7: wake_nudge event context includes agent_count + cc_count + note
# ============================================================================
section "T7: wake_nudge event context has agent_count, cc_count, note"
if grep -Fq 'agent_count: $queue' "$WATCH_SH" && \
   grep -Fq 'cc_count: $cc' "$WATCH_SH" && \
   grep -Fq 'note:' "$WATCH_SH"; then
  pass "wake_nudge context includes agent_count + cc_count + note"
else
  fail "wake_nudge context incomplete" "expected context.agent_count, context.cc_count, context.note fields"
fi

# ============================================================================
# T8: Katman 2 — wake_pane_for_role called with combined payload
# ============================================================================
section "T8: Katman 2 — wake_pane_for_role receives events + nudges"
if grep -Fq 'wake_payload' "$WATCH_SH" && \
   grep -Fq '$e + $n' "$WATCH_SH"; then
  pass "wake_pane_for_role called with combined payload (events + nudges)"
else
  fail "Katman 2 not applied" "expected wake_payload jq concat of events + nudges before wake_pane_for_role call"
fi

# ============================================================================
# T9: Wake nudge guarded by REPO env var
# ============================================================================
section "T9: wake_nudge computation guarded by REPO env var"
if grep -Fq '${REPO:-}' "$WATCH_SH"; then
  pass "wake_nudge computation guarded by REPO env var presence"
else
  fail "REPO guard missing" "expected '\${REPO:-}' guard around gh API calls"
fi

# ============================================================================
# Summary
# ============================================================================
printf "\n${B}==== SUMMARY ====${D}\n"
printf "  ${G}PASS${D}: %d\n" "$PASS"
printf "  ${R}FAIL${D}: %d\n" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0