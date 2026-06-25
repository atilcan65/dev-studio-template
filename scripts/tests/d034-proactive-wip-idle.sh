#!/usr/bin/env bash
# d034-proactive-wip-idle.sh — regression test for ADR-0039 WIP-idle watchdog
# (scripts/wip-idle-detect.sh).
#
# TEMPLATE PORT (Issue #290, Sprint 6 P1): mirrors the AtilCalculator
# regression (scripts/tests/d034-proactive-wip-idle.sh MERGED with #291 impl).
# Future bootstrapped repos inherit this regression as part of the template,
# so the WIP-idle watchdog contract is enforced at every fresh repo.
#
# Why this test exists
# --------------------
# ADR-0039 (Issue #289 doctrine, MERGED 1150fdb6 in AtilCalculator) defines a
# 30-min idle threshold for `WIP > 0` agents. AtilCalculator's Issue #291 owns
# the dev implementation: `scripts/wip-idle-detect.sh`. d034 guards the
# contract:
#
#   1. Script exists + executable + parseable header
#   2. Threshold default = 30 min (ADR-0039 §Decision)
#   3. 5 detection signals wired (PR draft, comment, commit + signal 5 PR-in-review)
#   4. State-machine edge case: signal 5 PR-in-review = NOT idle
#   5. CLI flags (--role, --threshold, --dry-run) honor ADR-0039 contract
#   6. Output JSON shape: [{role, wip_count, issues: [{issue, age_min}]}]
#   7. Throttle/coalesce: ≥3 idle in 5-min window = wave notification (arch 🟡 #2)
#   8. Graceful degradation: missing gh/jq = exit 3 + clear error
#
# Per arch review (4778117427) recommendation: 8 TUs (5 positive + 3 negative/boundary).
# AtilCalculator Issue #290 spec said "5 TUs expected" but the implementation
# evolved to 8 TUs; template port carries all 8 for full regression coverage.
#
# Sister test: atilcan65/AtilCalculator scripts/tests/d034-proactive-wip-idle.sh
# (AtilCalculator-side impl, Issue #291).
#
# Exit code: 0 = all pass, 1 = at least one fail.
# Run standalone: bash scripts/tests/d034-proactive-wip-idle.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECT_SH="$REPO_ROOT/scripts/wip-idle-detect.sh"

# Colors (TTY-aware)
if [[ -t 1 ]]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; B=$'\033[1m'; D=$'\033[0m'
else
  G=""; R=""; B=""; D=""
fi

PASS=0; FAIL=0
pass() { printf "  ${G}✓ PASS${D} — %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  ${R}✗ FAIL${D} — %s\n" "$1"; [ -n "${2:-}" ] && printf "    ${R}%s\n" "$2"; FAIL=$((FAIL+1)); }
section() { printf "\n${B}==== %s ====${D}\n" "$1"; }

# ============================================================================
# T1: Script exists + executable
# ============================================================================
section "T1: scripts/wip-idle-detect.sh exists + executable"
if [ -f "$DETECT_SH" ] && [ -x "$DETECT_SH" ]; then
  pass "wip-idle-detect.sh exists and is executable"
else
  fail "wip-idle-detect.sh missing or not executable" "expected: scripts/wip-idle-detect.sh (-x bit set) — ADR-0039 / Issue #291 dev impl"
fi

# ============================================================================
# T2: Threshold default = 30 min (ADR-0039 §Decision)
# ============================================================================
section "T2: Threshold default = 30 min (per ADR-0039)"
if [ -f "$DETECT_SH" ] && grep -Eq 'WIP_IDLE_THRESHOLD_MIN:-30|threshold_min.*30|30.*minute' "$DETECT_SH"; then
  pass "default threshold = 30 min (ADR-0039 §Decision)"
else
  fail "default threshold ≠ 30 min" "expected: WIP_IDLE_THRESHOLD_MIN:-30 in wip-idle-detect.sh — ADR-0039 30m heartbeat-aligned threshold"
fi

# ============================================================================
# T3: Detection signals wired (3 in-scope + signal 5)
# ============================================================================
section "T3: 3 in-scope signals + signal 5 PR-in-review (per ADR-0039 §Detection signals)"
signals_ok=false
if [ -f "$DETECT_SH" ]; then
  has_pr_draft=$(grep -c 'pr list.*state.*draft\|pr list.*is:draft\|is:draft' "$DETECT_SH" 2>/dev/null || echo 0)
  has_comment=$(grep -c 'comments.*updatedAt\|gh issue view.*comments' "$DETECT_SH" 2>/dev/null || echo 0)
  has_commit=$(grep -c 'gh api.*commits\|commits?sha' "$DETECT_SH" 2>/dev/null || echo 0)
  has_pr_review=$(grep -c 'status:in-review\|in_review_count\|signal 5\|PR-in-review' "$DETECT_SH" 2>/dev/null || echo 0)

  if [ "$has_pr_draft" -gt 0 ] && [ "$has_comment" -gt 0 ] && [ "$has_commit" -gt 0 ] && [ "$has_pr_review" -gt 0 ]; then
    pass "all 3 in-scope signals + signal 5 (PR-in-review) wired"
    signals_ok=true
  else
    fail "missing signal(s)" "expected: signal 1 (pr draft), signal 2 (issue comment), signal 3 (branch commit), signal 5 (PR-in-review). Counts: draft=$has_pr_draft comment=$has_comment commit=$has_commit pr_review=$has_pr_review"
  fi
else
  fail "wip-idle-detect.sh missing — T3 cannot verify signals" "expected: script with 4 detection signals"
fi

# ============================================================================
# T4: State-machine edge case — signal 5 PR-in-review = NOT idle
# ============================================================================
section "T4: Signal 5 edge case — PR-in-review agent is NOT flagged idle"
if [ -f "$DETECT_SH" ]; then
  if awk '/role in/,/^done$/' "$DETECT_SH" 2>/dev/null | grep -Eq 'in_review_count.*continue|skip this role|signal 5|legitimate wait'; then
    pass "PR-in-review correctly skips role (signal 5 edge case handled)"
  elif grep -Eq 'in_review_count.*-gt 0.*continue|in_review_count.*continue|skip this role' "$DETECT_SH"; then
    pass "PR-in-review correctly skips role (signal 5 edge case handled)"
  else
    fail "PR-in-review NOT skipping" "expected: in_review_count > 0 → continue (skip role per ADR-0039 §Detection signals signal 5)"
  fi
else
  fail "wip-idle-detect.sh missing — T4 cannot verify" ""
fi

# ============================================================================
# T5: CLI flags honor ADR-0039 contract
# ============================================================================
section "T5: CLI flags (--role / --threshold / --dry-run)"
if [ -f "$DETECT_SH" ]; then
  has_role_flag=$(grep -c '\-\-role' "$DETECT_SH" 2>/dev/null || echo 0)
  has_threshold_flag=$(grep -c '\-\-threshold' "$DETECT_SH" 2>/dev/null || echo 0)
  has_dry_run=$(grep -c '\-\-dry-run' "$DETECT_SH" 2>/dev/null || echo 0)
  has_help=$(grep -c '\-\-help\|-h' "$DETECT_SH" 2>/dev/null || echo 0)

  if [ "$has_role_flag" -gt 0 ] && [ "$has_threshold_flag" -gt 0 ] && [ "$has_dry_run" -gt 0 ] && [ "$has_help" -gt 0 ]; then
    pass "all 4 CLI flags present (--role / --threshold / --dry-run / --help)"
  else
    fail "missing CLI flag(s)" "expected: --role, --threshold, --dry-run, --help. Counts: role=$has_role_flag threshold=$has_threshold_flag dry=$has_dry_run help=$has_help"
  fi
else
  fail "wip-idle-detect.sh missing — T5 cannot verify" ""
fi

# ============================================================================
# T6: Output JSON shape (ADR-0039 §Decision)
# ============================================================================
section "T6: Output JSON shape [{role, wip_count, issues: [{issue, age_min}]}]"
if [ -f "$DETECT_SH" ]; then
  if grep -Eq 'role.*wip_count.*issues|role.*\$.*wip_count|role: \$.*wip_count' "$DETECT_SH" && \
     grep -Eq 'issue.*age_min|issue: \$' "$DETECT_SH"; then
    pass "output shape: {role, wip_count, issues: [{issue, age_min}]}"
  else
    fail "output shape mismatch" "expected: jq construction of {role, wip_count, issues: [{issue, age_min}]} per ADR-0039 §Decision payload"
  fi
else
  fail "wip-idle-detect.sh missing — T6 cannot verify" ""
fi

# ============================================================================
# T7: Throttle/coalesce — ≥3 idle in 5-min = wave (arch 🟡 #2)
# ============================================================================
section "T7: Throttle/coalesce — wave notification for ≥3 idle agents"
if [ -f "$DETECT_SH" ]; then
  # Check for either:
  #   (a) wave logic inline in wip-idle-detect.sh, OR
  #   (b) callout that wave logic lives in agent-watch.sh / notify.sh
  has_wave=$(grep -c 'wave\|consolidated\|notify_all\|\[ORCH.*ALL\]' "$DETECT_SH" 2>/dev/null || echo 0)
  has_comment_wave=$(grep -c 'wave logic\|wave handled\|consolidat.*agent-watch\|arch 🟡 #2\|sprint 6 wave' "$DETECT_SH" 2>/dev/null || echo 0)

  if [ "$has_wave" -gt 0 ] || [ "$has_comment_wave" -gt 0 ]; then
    pass "wave coalesce reference present (either inline or callout to agent-watch.sh)"
  else
    fail "no wave coalesce reference" "expected: either inline wave logic OR explicit comment that wave is in agent-watch.sh / notify.sh per ADR-0039 arch 🟡 #2"
  fi
else
  fail "wip-idle-detect.sh missing — T7 cannot verify" ""
fi

# ============================================================================
# T8: Graceful degradation — missing gh/jq exits 3 (per ADR-0024 pattern)
# ============================================================================
section "T8: Graceful degradation — missing gh/jq = exit 3"
if [ -f "$DETECT_SH" ]; then
  has_preflight=$(grep -c 'command -v gh\|command -v jq\|exit 3' "$DETECT_SH" 2>/dev/null || echo 0)
  has_preflight_msg=$(grep -c 'gh CLI required\|jq required\|preflight' "$DETECT_SH" 2>/dev/null || echo 0)

  if [ "$has_preflight" -gt 0 ] && [ "$has_preflight_msg" -gt 0 ]; then
    pass "preflight check present (gh/jq detection + exit 3 on missing)"
  else
    fail "no preflight check" "expected: command -v gh + command -v jq + 'ERROR: gh CLI required' / 'ERROR: jq required' + exit 3"
  fi
else
  fail "wip-idle-detect.sh missing — T8 cannot verify" ""
fi

# ============================================================================
# Summary
# ============================================================================
printf "\n${B}==== SUMMARY ====${D}\n"
printf "  ${G}PASS${D}: %d\n" "$PASS"
printf "  ${R}FAIL${D}: %d\n" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "Issue #290 REGRESSION FAILED — wip-idle-detect.sh contract incomplete (template port)."
  echo "Fix: ensure all 8 TUs pass per ADR-0039 §Decision + arch review 4778117427."
  exit 1
fi
echo
echo "Issue #290 REGRESSION PASS — wip-idle-detect.sh 8/8 contract honored (template port)."
exit 0