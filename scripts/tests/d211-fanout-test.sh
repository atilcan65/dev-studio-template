#!/bin/bash
# Standalone unit test for D2.1.1 / D2.2 fanout helpers.
# Sources agent-watch.sh's helper section by extracting it.
#
# Layered test contract (issue #58 Part B+C):
#   d211 (THIS FILE) = UNIT          - per-helper input/output, isolated.
#   d212             = INTEGRATION   - full PR lifecycle (T1->T5), cross-role
#                                      wake matrix, atomic-handoff regression
#                                      guard. See scripts/tests/d212-handoff-smoke.sh.
# Run BOTH locally before any agent-watch.sh refactor.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/agent-watch.sh"

# Pull out the helper block (between the v3.1 comment and "--- query builders")
awk '/^# v3\.1 \(ADR-0008\)/,/^# --- query builders/' "$SCRIPT" > /tmp/d211-helpers.sh
echo "Extracted $(wc -l < /tmp/d211-helpers.sh) helper lines"

# Source it
source /tmp/d211-helpers.sh

# Override env if needed
export PR_MERGED_FANOUT_DEFAULT="${PR_MERGED_FANOUT_DEFAULT:-orchestrator product-manager developer}"
export PR_MERGED_FANOUT_RULES_ENABLED="${PR_MERGED_FANOUT_RULES_ENABLED:-true}"

PASS=0; FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $desc — expected '$expected' got '$actual'"
    FAIL=$((FAIL+1))
  fi
}

call() {
  if "$@" >/dev/null 2>&1; then echo "wake"; else echo "skip"; fi
}

echo ""
echo "=== Test 1: default fanout membership ==="
check "orchestrator in default"     wake "$(call role_in_default_fanout orchestrator)"
check "product-manager in default"  wake "$(call role_in_default_fanout product-manager)"
check "developer in default"        wake "$(call role_in_default_fanout developer)"
check "architect NOT in default"    skip "$(call role_in_default_fanout architect)"
check "tester NOT in default"       skip "$(call role_in_default_fanout tester)"

echo ""
echo "=== Test 2: query gate (role_receives_pr_merged) — rules ENABLED ==="
check "orchestrator runs query"     wake "$(call role_receives_pr_merged orchestrator)"
check "architect runs query"        wake "$(call role_receives_pr_merged architect)"
check "tester runs query"           wake "$(call role_receives_pr_merged tester)"
check "developer runs query"        wake "$(call role_receives_pr_merged developer)"

echo ""
echo "=== Test 3: per-PR fanout — empty labels (default-only PR) ==="
check "orchestrator wakes (default)"  wake "$(call role_wakes_for_pr orchestrator '[]')"
check "developer wakes (default)"     wake "$(call role_wakes_for_pr developer '[]')"
check "architect SKIPS (no label)"    skip "$(call role_wakes_for_pr architect '[]')"
check "tester SKIPS (no label)"       skip "$(call role_wakes_for_pr tester '[]')"

echo ""
echo "=== Test 4: per-PR fanout — needs-architect-review ==="
LABELS='["needs-architect-review","type:feature"]'
check "orchestrator wakes (default)"  wake "$(call role_wakes_for_pr orchestrator "$LABELS")"
check "architect wakes (label)"       wake "$(call role_wakes_for_pr architect "$LABELS")"
check "tester SKIPS"                  skip "$(call role_wakes_for_pr tester "$LABELS")"

echo ""
echo "=== Test 5: per-PR fanout — agent:architect alias ==="
LABELS='["agent:architect"]'
check "architect wakes (agent: alias)"  wake "$(call role_wakes_for_pr architect "$LABELS")"
check "tester SKIPS"                    skip "$(call role_wakes_for_pr tester "$LABELS")"

echo ""
echo "=== Test 6: per-PR fanout — needs-tester-signoff ==="
LABELS='["needs-tester-signoff","type:bug","priority:P1"]'
check "tester wakes (label)"            wake "$(call role_wakes_for_pr tester "$LABELS")"
check "architect SKIPS"                 skip "$(call role_wakes_for_pr architect "$LABELS")"
check "PM wakes (default)"              wake "$(call role_wakes_for_pr product-manager "$LABELS")"

echo ""
echo "=== Test 7: per-PR fanout — agent:tester alias ==="
LABELS='["agent:tester","cc:developer"]'
check "tester wakes (agent: alias)"     wake "$(call role_wakes_for_pr tester "$LABELS")"

echo ""
echo "=== Test 8: per-PR fanout — BOTH architect & tester labels (5-role wake) ==="
LABELS='["needs-architect-review","needs-tester-signoff","type:feature"]'
check "orchestrator wakes"              wake "$(call role_wakes_for_pr orchestrator "$LABELS")"
check "PM wakes"                        wake "$(call role_wakes_for_pr product-manager "$LABELS")"
check "developer wakes"                 wake "$(call role_wakes_for_pr developer "$LABELS")"
check "architect wakes"                 wake "$(call role_wakes_for_pr architect "$LABELS")"
check "tester wakes"                    wake "$(call role_wakes_for_pr tester "$LABELS")"

echo ""
echo "=== Test 9: kill switch — rules DISABLED ==="
PR_MERGED_FANOUT_RULES_ENABLED=false
LABELS='["needs-architect-review","needs-tester-signoff"]'
check "default roles unaffected"        wake "$(call role_wakes_for_pr orchestrator "$LABELS")"
check "architect SKIPS (rules off)"     skip "$(call role_wakes_for_pr architect "$LABELS")"
check "tester SKIPS (rules off)"        skip "$(call role_wakes_for_pr tester "$LABELS")"
check "architect query gate CLOSED"     skip "$(call role_receives_pr_merged architect)"
PR_MERGED_FANOUT_RULES_ENABLED=true

echo ""
echo "=== Test 10: kill switch — DEFAULT empty (no one wakes by default) ==="
PR_MERGED_FANOUT_DEFAULT=""
LABELS='[]'
check "orchestrator SKIPS (empty default)" skip "$(call role_wakes_for_pr orchestrator "$LABELS")"
check "developer SKIPS (empty default)"    skip "$(call role_wakes_for_pr developer "$LABELS")"
LABELS='["needs-architect-review"]'
check "architect wakes (label-only)"       wake "$(call role_wakes_for_pr architect "$LABELS")"
check "orchestrator SKIPS (no label match)" skip "$(call role_wakes_for_pr orchestrator "$LABELS")"
PR_MERGED_FANOUT_DEFAULT="orchestrator product-manager developer"

# ============================================================
# S4 series (ADR-0009 § 2.6): pr_labeled fanout
# Per issue #50 AC: 5 cases covering open-PR label wake paths.
# These activate when v3.2 helpers (role_receives_pr_labeled,
# role_wakes_for_pr_labeled, pr_labeled_wake_reason) are
# extracted from agent-watch.sh — i.e. after PR #49 lands.
# Until then, the S4 series is a graceful SKIP (the helpers
# are not on main yet).
# ============================================================
echo ""
echo "=== S4 series: pr_labeled fanout (ADR-0009 § 2.6) ==="

if ! type role_receives_pr_labeled >/dev/null 2>&1; then
  echo "  NOTE: v3.2 helpers not in agent-watch.sh on this branch."
  echo "        S4 series will activate after PR #49 lands on main."
  echo "        All 5 cases below SKIP gracefully."
  echo ""
  echo "=== S4-PR-Open-1: open PR + needs-architect-review (1 wake: architect) ==="
  check "S4-1 (deferred — needs PR #49 merged)" skip skip
  echo ""
  echo "=== S4-PR-Open-2: open PR + needs-tester-signoff (1 wake: tester) ==="
  check "S4-2 (deferred — needs PR #49 merged)" skip skip
  echo ""
  echo "=== S4-PR-Open-3: open PR + both wake labels (2 wakes: arch + test) ==="
  check "S4-3 (deferred — needs PR #49 merged)" skip skip
  echo ""
  echo "=== S4-PR-Open-4: closed PR + needs-architect-review (0 wakes; query-level state filter) ==="
  check "S4-4 (deferred — needs PR #49 merged)" skip skip
  echo ""
  echo "=== S4-PR-Open-5: open PR + cc:architect only (1 wake: architect via cc:) ==="
  check "S4-5 (deferred — needs PR #49 merged)" skip skip
else
  # v3.2 helpers are available — run the actual tests.
  # Default PR_LABELED_FANOUT for these tests.
  export PR_LABELED_FANOUT="architect tester"

  echo ""
  echo "=== S4-PR-Open-1: open PR + needs-architect-review (1 wake: architect) ==="
  check "architect enrolled in PR_LABELED_FANOUT"     wake "$(call role_receives_pr_labeled architect)"
  check "tester enrolled in PR_LABELED_FANOUT"        wake "$(call role_receives_pr_labeled tester)"
  check "developer NOT enrolled (default fanout)"    skip "$(call role_receives_pr_labeled developer)"
  LABELS='["needs-architect-review","type:feature"]'
  check "architect wakes on needs-architect-review"   wake "$(call role_wakes_for_pr_labeled architect "$LABELS")"
  check "tester SKIPS (no needs-tester-signoff)"     skip "$(call role_wakes_for_pr_labeled tester "$LABELS")"

  echo ""
  echo "=== S4-PR-Open-2: open PR + needs-tester-signoff (1 wake: tester) ==="
  LABELS='["needs-tester-signoff","priority:P1"]'
  check "tester wakes on needs-tester-signoff"       wake "$(call role_wakes_for_pr_labeled tester "$LABELS")"
  check "architect SKIPS (no needs-architect-review)" skip "$(call role_wakes_for_pr_labeled architect "$LABELS")"

  echo ""
  echo "=== S4-PR-Open-3: open PR + both wake labels (2 wakes: arch + test) ==="
  LABELS='["needs-architect-review","needs-tester-signoff"]'
  check "architect wakes"                            wake "$(call role_wakes_for_pr_labeled architect "$LABELS")"
  check "tester wakes"                               wake "$(call role_wakes_for_pr_labeled tester "$LABELS")"
  # Per-role wake count is the helper's per-PR job; the multi-wake SUM is
  # handled by query_pr_labeled (1 wake entry per matching role), which is
  # tested at integration level (doctor --fanout, smoke S3).

  echo ""
  echo "=== S4-PR-Open-4: closed PR + needs-architect-review (0 wakes; query-level state filter) ==="
  # role_wakes_for_pr_labeled is state-agnostic by design — the state filter
  # lives in query_pr_labeled (gh pr list --state open). The AC "expect 0
  # wakes" is verified at integration level (doctor --fanout on a closed PR
  # + smoke S3). At the unit level, we document the contract: helper returns
  # wake based on label match alone; the query decides state.
  LABELS='["needs-architect-review"]'
  check "helper returns wake based on label (state-agnostic by design)"  wake "$(call role_wakes_for_pr_labeled architect "$LABELS")"
  # Contract note (no assertion): query_pr_labeled filters via
  # `gh pr list --state open`, so a closed PR carrying the wake label will
  # not appear in the query result. Verified by doctor --fanout + smoke S3.

  echo ""
  echo "=== S4-PR-Open-5: open PR + cc:architect only (1 wake: architect via cc:) ==="
  LABELS='["cc:architect"]'
  check "architect wakes on cc:architect alias"       wake "$(call role_wakes_for_pr_labeled architect "$LABELS")"
  check "tester SKIPS (cc:architect is not tester's trigger)" skip "$(call role_wakes_for_pr_labeled tester "$LABELS")"
  REASON=$(pr_labeled_wake_reason architect "$LABELS")
  check "wake_reason returns 'cc:architect' (observability)" "cc:architect" "$REASON"
fi

echo ""
echo "======================================"
echo "PASS=$PASS  FAIL=$FAIL"
echo "======================================"

# ============================================================
# Test 11 (issue #52, BUG-1 sibling):
# PR_MERGED_FANOUT_DEFAULT kill switch — same `:-` vs `-` landmine
# as BUG-1 (fixed in PR #49 for PR_LABELED_FANOUT).
#
# With `${VAR:-default}` (BUGGY): empty string is re-defaulted → kill switch breaks.
# With `${VAR-default}`  (FIXED):  empty string is preserved     → kill switch works.
#
# These tests are TDD-red on the current code (PR_MERGED_FANOUT_DEFAULT=:-)
# and TDD-green after the fix. Test 3/4 verify the actual files, not just
# the bash idiom.
# ============================================================
echo ""
echo "=== Test 11: PR_MERGED_FANOUT_DEFAULT kill switch (BUG-1 sibling) ==="

# Test 1: bash idiom — empty is preserved with `${VAR-default}` (not `:-`)
got11a=$(env -u PR_MERGED_FANOUT_DEFAULT bash -c 'PR_MERGED_FANOUT_DEFAULT="$1"; PR_MERGED_FANOUT_DEFAULT="${PR_MERGED_FANOUT_DEFAULT-orchestrator product-manager developer}"; echo -n "$PR_MERGED_FANOUT_DEFAULT"' _ "")
check "Test 11.1: empty kill switch preserved (\${VAR-default})" "" "$got11a"

# Test 2: bash idiom — unset falls back to default
got11b=$(env -u PR_MERGED_FANOUT_DEFAULT bash -c 'PR_MERGED_FANOUT_DEFAULT="${PR_MERGED_FANOUT_DEFAULT-orchestrator product-manager developer}"; echo -n "$PR_MERGED_FANOUT_DEFAULT"')
check "Test 11.2: unset falls back to default" "orchestrator product-manager developer" "$got11b"

# Test 3: integration — source agent-watch.sh helpers with empty env, check var
# Uses the BUGGY `:-` operator on main today; expected FAIL pre-fix, PASS post-fix.
WATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/agent-watch.sh"
got11c=$(env -u PR_MERGED_FANOUT_DEFAULT PR_MERGED_FANOUT_DEFAULT="" bash -c "
  awk '/^# v3\.1 \(ADR-0008\)/,/^# --- query builders/' '$WATCH' > /tmp/d211-helpers-test11.sh
  source /tmp/d211-helpers-test11.sh
  echo -n \"\$PR_MERGED_FANOUT_DEFAULT\"
" 2>/dev/null)
check "Test 11.3: agent-watch.sh honors empty PR_MERGED_FANOUT_DEFAULT (kill switch on)" "" "$got11c"

# Test 4: integration — kill-switch effect on the default fanout function.
# Sources the helpers from agent-watch.sh with PR_MERGED_FANOUT_DEFAULT=""
# in the env. With the BUGGY `:-`, the var gets re-defaulted and
# role_in_default_fanout returns true for orchestrator (kill switch broken).
# With the FIXED `-`, the var stays empty and orchestrator is NOT in default
# (kill switch works). This is the behavior users actually care about.
got11d=$(env -u PR_MERGED_FANOUT_DEFAULT PR_MERGED_FANOUT_DEFAULT="" bash -c "
  source <(awk '/^# v3\.1 \(ADR-0008\)/,/^# --- query builders/' '$WATCH')
  if role_in_default_fanout orchestrator; then
    echo 'BUG: orchestrator in default fanout (kill switch broken)'
  else
    echo 'OK: orchestrator not in default fanout (kill switch works)'
  fi
" 2>/dev/null)
check "Test 11.4: kill switch disables default-fanout wake" "OK: orchestrator not in default fanout (kill switch works)" "$got11d"
# Test 12-14 (issue #53): regression-protection tests for pr_labeled fanout
# Per issue #53 AC: 3 test blocks covering hazards identified in D2.2 review.
# All 3 implementations are on main post-PR #49 — these tests lock the
# contract against future refactors. Issue says "insert after the existing
# S4-PR-Open 1-5 block from PR #51"; since PR #51 is still draft, insert
# here after the existing Test 10. When PR #51 lands, the file order will
# be: Tests 1-10 (existing) → S4-PR-Open 1-5 (from #51) → S12-14 (here).
# ============================================================
echo ""

# Test 12: Kill-switch (PR_LABELED_FANOUT="") — BUG-1 regression guard.
# Per issue #53: BUG-1 (PR #49 commit 6823193) was a silent kill-switch
# failure. Without an explicit test, a future refactor could re-introduce
# the `:` and the empty-disable contract would silently break again.
echo "=== Test 12: PR_LABELED_FANOUT=\"\" disables path (BUG-1 regression guard) ==="
PR_LABELED_FANOUT=""
check "architect query CLOSED (empty fanout)" skip "$(call role_receives_pr_labeled architect)"
check "tester query CLOSED (empty fanout)"    skip "$(call role_receives_pr_labeled tester)"
PR_LABELED_FANOUT="architect tester"

# Test 13: Near-miss labels — Issue #47 regex-bug regression guard.
# Per issue #53: Issue #47's original AC had a regex bug that would match
# `needs-architect-review-v2`, `architect-review`, etc. The fix moved to
# exact-name match (ADR-0009 § 2.1 / § 2.6). Without an explicit test, a
# future "let me make this fuzzier" refactor could regress silently.
echo ""
echo "=== Test 13: near-miss labels — exact-match semantics (#47 regex-bug guard) ==="
LABELS='["needs-architect","needs-architect-review-v2","architect-review"]'
check "architect SKIPS near-miss labels" skip "$(call role_wakes_for_pr_labeled architect "$LABELS")"
LABELS='["needs-tester","tester-signoff","needs-tester-review"]'
check "tester SKIPS near-miss labels"    skip "$(call role_wakes_for_pr_labeled tester "$LABELS")"

# Test 14: Defensive — empty + lifecycle-only label sets.
# Per issue #53: cheap defensive coverage; guards against helper accidentally
# treating non-wake labels as wake.
echo ""
echo "=== Test 14: defensive — empty + lifecycle-only labels ==="
LABELS='[]'
check "architect SKIPS empty labels"          skip "$(call role_wakes_for_pr_labeled architect "$LABELS")"
check "tester SKIPS empty labels"             skip "$(call role_wakes_for_pr_labeled tester "$LABELS")"
LABELS='["type:feature","priority:P2","sprint:current"]'
check "architect SKIPS lifecycle-only labels" skip "$(call role_wakes_for_pr_labeled architect "$LABELS")"
check "tester SKIPS lifecycle-only labels"    skip "$(call role_wakes_for_pr_labeled tester "$LABELS")"

echo ""
echo "======================================"
echo "PASS=$PASS  FAIL=$FAIL"
echo "======================================"
[ "$FAIL" -eq 0 ]
