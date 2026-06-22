#!/usr/bin/env bash
# d024-agent-wake.sh — regression test for ADR-0033 dual-channel wake (Issue #221)
#
# Why this test exists
# --------------------
# PR #223 (ADR-0033 Auto-Ping dual-channel doctrine) shipped the design but the
# impl was deferred. Owner-approved 2026-06-22T06:35Z; dev impl scope:
#   - scripts/agent-wake.sh (new) — tmux send-keys wrapper, standalone CLI
#   - scripts/notify.sh --wake / -w flag amend — Telegram + agent-wake.sh
#   - scripts/tests/d024-agent-wake.sh (this file) — regression coverage
#
# Without this test, future refactors + the #222 template port can silently
# break dual-channel wake (which would re-introduce the RCA-19 silent-idle
# class of bugs).
#
# Template port: Issue #222. Reference impl is in atilcan65/AtilCalculator at
# commit ecbf21a (PR #239 merge). Tests written FIRST per TDD red→green
# discipline; d024 expected 0/7 (impl missing) before agent-wake.sh + notify.sh
# port, then 7/7 after.
#
# Test cases (per ADR-0033 §Test contract, PR #223):
#   T1: agent-wake.sh — role targeting → tmux send-keys with correct pane id + Enter
#   T2: agent-wake.sh — no tmux → silent no-op, exit 0
#   T3: agent-wake.sh — unknown role → silent no-op, exit 0
#   T4: agent-wake.sh — missing args → usage error, exit 2
#   T5: notify.sh -w -r developer → Telegram + agent-wake.sh call (both channels fire)
#   T6: notify.sh -w (no -r) → exit 2 + error message (-r required when -w set)
#   T7: backtick literal-mode → tmux send-keys -l (no expansion in payload)
#
# Exit code: 0 = all pass, 1 = at least one fail.
#
# Run standalone: bash scripts/tests/d024-agent-wake.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAKE_SH="$SCRIPT_DIR/../agent-wake.sh"
NOTIFY_SH="$SCRIPT_DIR/../notify.sh"

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
if [ ! -r "$NOTIFY_SH" ]; then
  echo "ERROR: notify.sh not found at $NOTIFY_SH" >&2; exit 127
fi

# ============================================================================
# T1: agent-wake.sh — role targeting → tmux send-keys + Enter
# ============================================================================
section "T1: agent-wake.sh — role → tmux send-keys with Enter"
# Pattern: standalone CLI, role-to-pane index map (orchestrator=0, developer=3,
# tester=4, etc.), tmux send-keys followed by Enter, literal-mode (-l).
if [ ! -f "$WAKE_SH" ]; then
  fail "agent-wake.sh missing" "expected new file at $WAKE_SH (refs Issue #221 / #222 scope)"
elif ! grep -Eq 'tmux send-keys' "$WAKE_SH"; then
  fail "tmux send-keys call missing" "expected 'tmux send-keys' in $WAKE_SH"
elif ! grep -Eq 'pane_id' "$WAKE_SH"; then
  fail "pane_id lookup missing" "expected pane_id variable + role-to-pane mapping in $WAKE_SH"
elif ! grep -Eq 'send-keys.*Enter|tmux send-keys.*Enter' "$WAKE_SH"; then
  fail "Enter key injection missing" "expected 'tmux send-keys ... Enter' after the message"
elif ! grep -Eq 'orchestrator.*main\.0|orchestrator.*0\.0|developer.*main\.3|developer.*3\.0' "$WAKE_SH"; then
  fail "role-to-pane index map missing" "expected fallback index map: orchestrator=main.0, developer=main.3, tester=main.4 (per agent-context-monitor.sh layout)"
else
  pass "agent-wake.sh role targeting present (send-keys + Enter + index map)"
fi

# ============================================================================
# T2: agent-wake.sh — no tmux → silent no-op, exit 0
# ============================================================================
section "T2: agent-wake.sh — no tmux → silent no-op, exit 0"
# Pattern: `command -v tmux >/dev/null 2>&1 || return 0` (or equivalent early-exit)
# so that calling on a host without tmux doesn't error.
if [ ! -f "$WAKE_SH" ]; then
  fail "agent-wake.sh missing" "expected $WAKE_SH to exist (T2 depends on T1)"
elif grep -Eq 'command -v tmux.*\|\|.*return 0|command -v tmux.*\|\|.*exit 0|tmux has-session.*\|\|.*return 0|tmux has-session.*\|\|.*exit 0' "$WAKE_SH"; then
  pass "no-tmux early-exit present (silent no-op + exit 0)"
else
  fail "no-tmux early-exit missing" "expected 'command -v tmux >/dev/null 2>&1 || return 0' or 'tmux has-session ... || return 0' so missing tmux is silent no-op (not error)"
fi

# ============================================================================
# T3: agent-wake.sh — unknown role → silent no-op, exit 0
# ============================================================================
section "T3: agent-wake.sh — unknown role → silent no-op, exit 0"
# Pattern: case statement on role with `*) return 0` or `*) exit 0` for unknown.
# Backward-compat: invalid roles must NOT error (silent skip) so an upstream
# typo doesn't break the caller's main flow.
if [ ! -f "$WAKE_SH" ]; then
  fail "agent-wake.sh missing" "expected $WAKE_SH to exist (T3 depends on T1)"
elif grep -Eq '\*\).*return 0|\*\).*exit 0' "$WAKE_SH"; then
  pass "unknown-role silent no-op present (case *) return 0 / exit 0)"
else
  fail "unknown-role silent no-op missing" "expected case statement ending with '*) return 0' or '*) exit 0' for unknown roles (silent skip, not error)"
fi

# ============================================================================
# T4: agent-wake.sh — missing args → usage error, exit 2
# ============================================================================
section "T4: agent-wake.sh — missing args → usage error, exit 2"
# Pattern: if [ $# -lt 2 ] || [ -z "$ROLE" ] || [ -z "$MSG" ]; then echo usage; exit 2
# Mirrors notify.sh's exit-2-on-missing-args convention.
if [ ! -f "$WAKE_SH" ]; then
  fail "agent-wake.sh missing" "expected $WAKE_SH to exist (T4 depends on T1)"
elif grep -Eq 'exit 2' "$WAKE_SH" && grep -Eq 'Usage|usage' "$WAKE_SH"; then
  pass "usage-error + exit 2 present (missing args handled)"
else
  fail "usage-error + exit 2 missing" "expected 'Usage: ...' message + 'exit 2' when args missing (matches notify.sh convention)"
fi

# ============================================================================
# T5: notify.sh -w -r <role> → Telegram + agent-wake.sh both fire (dual-channel)
# ============================================================================
section "T5: notify.sh -w -r <role> → Telegram + agent-wake.sh call"
# Pattern: notify.sh has -w flag (wake) + -r flag (role). When both set, after
# the Telegram POST, notify.sh must invoke scripts/agent-wake.sh to inject
# the wake prompt into the target pane. The dual-channel is the core fix.
if grep -Eq '\-w\b|wake\b' "$NOTIFY_SH" && \
   grep -Eq '\-r\b' "$NOTIFY_SH" && \
   grep -Eq 'agent-wake\.sh' "$NOTIFY_SH"; then
  pass "dual-channel wiring present (notify.sh -w/-r + agent-wake.sh invocation)"
else
  fail "dual-channel wiring missing" "expected notify.sh to have -w flag, -r flag, AND invoke scripts/agent-wake.sh when both are set"
fi

# ============================================================================
# T6: notify.sh -w (no -r) → exit 2 + error message (-r required when -w set)
# ============================================================================
section "T6: notify.sh -w without -r → exit 2 + error"
# Pattern: explicit check that -w requires -r. If -w set but -r missing,
# notify.sh exits 2 with an error (mirrors ADR-0033 §Test contract #6).
if grep -Eq 'role.*required|-r.*required|wake.*role' "$NOTIFY_SH" && \
   grep -Eq 'exit 2' "$NOTIFY_SH"; then
  pass "-w requires -r check present (exit 2 on missing role)"
else
  fail "-w/-r requirement check missing" "expected notify.sh to check that -w requires -r, exit 2 with error if missing (ADR-0033 §Test contract #6)"
fi

# ============================================================================
# T7: backtick literal-mode → tmux send-keys -l (no expansion in payload)
# ============================================================================
section "T7: send-keys literal-mode → no expansion of backticks/dollar"
# Pattern: `tmux send-keys -t ... -l "$msg"` (the -l flag is literal mode).
# Without -l, tmux interprets special chars ($VAR, `cmd`, etc.) and corrupts
# the wake prompt. This is the canonical "backticks survive" lock-in.
if [ ! -f "$WAKE_SH" ]; then
  fail "agent-wake.sh missing" "expected $WAKE_SH to exist (T7 depends on T1)"
elif grep -Eq 'send-keys.*-l|send-keys -l' "$WAKE_SH"; then
  pass "literal-mode (-l) on send-keys present (backticks survive)"
else
  fail "literal-mode (-l) on send-keys missing" "expected 'tmux send-keys ... -l' (the -l flag = literal mode). Without -l, backticks and \$VAR in the wake prompt would be interpreted, corrupting the message."
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
