#!/bin/bash
# Standalone unit test for D2.1.1 fanout helpers.
# Sources agent-watch.sh's helper section by extracting it.
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

echo ""
echo "======================================"
echo "PASS=$PASS  FAIL=$FAIL"
echo "======================================"
[ "$FAIL" -eq 0 ]
