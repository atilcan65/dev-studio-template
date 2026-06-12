#!/bin/bash
# d212-handoff-smoke.sh — D2.2 atomic handoff smoke test (integration-level).
#
# Purpose
# -------
# d211 (unit) verifies helper fns in isolation: given a role + a labels JSON,
# does the helper return wake/skip? d212 (this file, integration) simulates a
# real PR's lifecycle by walking 5 transitions of the labels array and, at each
# step, asserts the FULL 5-role wake matrix.
#
# Why this exists
# ---------------
# A future refactor of agent-watch.sh's wake helpers could silently break the
# atomic-handoff contract (BUG-3 lesson, fixed by phantom-wake patch). d211
# catches per-helper regressions; d212 catches *cross-helper* / *lifecycle*
# regressions that only surface when labels flow through the real transitions.
#
# How it differs from d211
# ------------------------
#   d211 = unit:        one helper, one labels-snapshot, one role at a time.
#   d212 = integration: walk T1→T5, at each T assert WHO wakes + WHO skips
#                       across all 5 roles, for BOTH gates (pr_merged + pr_labeled).
#
# Source-of-truth: agent-watch.sh helpers (same extraction trick as d211, so we
# never duplicate logic). Pure-bash; no gh / no network / no tmux.
#
# Exit non-zero if FAIL > 0. Target: PASS≥12 FAIL=0.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/agent-watch.sh"

# Reuse d211's helper-extraction window so any v3.1/v3.2 helper updates flow
# through here automatically.
awk '/^# v3\.1 \(ADR-0008\)/,/^# --- query builders/' "$SCRIPT" > /tmp/d212-helpers.sh
echo "Extracted $(wc -l < /tmp/d212-helpers.sh) helper lines from agent-watch.sh"
# shellcheck disable=SC1091
source /tmp/d212-helpers.sh

# Defaults match production (ADR-0008 § default fanout, ADR-0009 § PR_LABELED_FANOUT).
export PR_MERGED_FANOUT_DEFAULT="${PR_MERGED_FANOUT_DEFAULT-orchestrator product-manager developer}"
export PR_MERGED_FANOUT_RULES_ENABLED="${PR_MERGED_FANOUT_RULES_ENABLED:-true}"
export PR_LABELED_FANOUT="${PR_LABELED_FANOUT-architect tester}"

PASS=0; FAIL=0
ALL_ROLES=(orchestrator product-manager developer architect tester)

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

# wake_state — returns "wake" if the role would wake for an OPEN PR carrying
# $labels via the pr_labeled gate (D2.2 path). "skip" otherwise.
wake_state_labeled() {
  local role="$1" labels="$2"
  if role_receives_pr_labeled "$role" && role_wakes_for_pr_labeled "$role" "$labels"; then
    echo "wake"
  else
    echo "skip"
  fi
}

# wake_state_merged — returns "wake"/"skip" for the pr_merged gate (D2.1 path),
# i.e. what would happen if this PR were MERGED carrying $labels.
wake_state_merged() {
  local role="$1" labels="$2"
  if role_wakes_for_pr "$role" "$labels"; then
    echo "wake"
  else
    echo "skip"
  fi
}

# Assert the full 5-role wake matrix at a given transition.
# $1 = transition label, $2 = labels JSON, $3..$7 = expected wake/skip per role
# (order: orchestrator, product-manager, developer, architect, tester),
# $8 = gate ("labeled" or "merged").
assert_matrix() {
  local tname="$1" labels="$2" gate="$8"
  local exp=("$3" "$4" "$5" "$6" "$7")
  local i=0
  for role in "${ALL_ROLES[@]}"; do
    local got
    if [ "$gate" = "labeled" ]; then
      got=$(wake_state_labeled "$role" "$labels")
    else
      got=$(wake_state_merged "$role" "$labels")
    fi
    check "[$tname/$gate] $role" "${exp[$i]}" "$got"
    i=$((i+1))
  done
}

echo ""
echo "================================================================"
echo "D2.2 atomic-handoff smoke (integration). Walks a single PR through"
echo "its label lifecycle and asserts the 5-role wake matrix per step."
echo "================================================================"

# ----------------------------------------------------------------------------
# Transition 1 — PR just opened, no review labels yet.
# Expected (pr_labeled gate): NOBODY wakes via labels (no wake-trigger label).
# Expected (pr_merged  gate): only default fanout (orch/PM/dev) — never run
#                             here because PR isn't merged, but the helper
#                             still tells us what *would* happen on merge.
# ----------------------------------------------------------------------------
echo ""
echo "=== T1: PR opened, labels=['type:feature','priority:P2'] ==="
T1='["type:feature","priority:P2"]'
#                                            orch  PM    dev   arch  test
assert_matrix "T1" "$T1"                     skip  skip  skip  skip  skip  labeled
assert_matrix "T1" "$T1"                     wake  wake  wake  skip  skip  merged

# ----------------------------------------------------------------------------
# Transition 2 — orchestrator/dev added 'needs-architect-review'.
# Expected (labeled): architect wakes, tester does NOT (no signoff label yet).
# Default-fanout roles are NOT enrolled in PR_LABELED_FANOUT → skip on labeled
# gate even though they'd wake on merge.
# ----------------------------------------------------------------------------
echo ""
echo "=== T2: +needs-architect-review (architect summoned) ==="
T2='["type:feature","priority:P2","needs-architect-review"]'
assert_matrix "T2" "$T2"                     skip  skip  skip  wake  skip  labeled
assert_matrix "T2" "$T2"                     wake  wake  wake  wake  skip  merged

# Observability: wake_reason returns the exact trigger label.
got_reason_t2=$(pr_labeled_wake_reason architect "$T2")
check "[T2/labeled] architect wake_reason=needs-architect-review" \
  "needs-architect-review" "$got_reason_t2"

# ----------------------------------------------------------------------------
# Transition 3 — architect finished, did atomic handoff:
#   removed: needs-architect-review
#   added:   needs-tester-signoff
# Expected (labeled): architect STOPS waking, tester STARTS waking.
# This is the core BUG-3-class regression guard: handoff must be visible at
# the helper level (the cross-role wake matrix flips correctly).
# ----------------------------------------------------------------------------
echo ""
echo "=== T3: architect→tester atomic handoff ==="
T3='["type:feature","priority:P2","needs-tester-signoff"]'
assert_matrix "T3" "$T3"                     skip  skip  skip  skip  wake  labeled
assert_matrix "T3" "$T3"                     wake  wake  wake  skip  wake  merged

got_reason_t3=$(pr_labeled_wake_reason tester "$T3")
check "[T3/labeled] tester wake_reason=needs-tester-signoff" \
  "needs-tester-signoff" "$got_reason_t3"

# Cross-check: architect's wake_reason at T3 is empty (no trigger label remains).
got_arch_reason_t3=$(pr_labeled_wake_reason architect "$T3")
check "[T3/labeled] architect wake_reason='' (no trigger left)" \
  "" "$got_arch_reason_t3"

# ----------------------------------------------------------------------------
# Transition 4 — tester wants a second architect pass (re-summons):
#   added BOTH: needs-architect-review + needs-tester-signoff
# Expected (labeled): both architect AND tester wake (parallel review fan-out).
# ----------------------------------------------------------------------------
echo ""
echo "=== T4: tester re-summons architect (both labels present) ==="
T4='["type:feature","priority:P2","needs-architect-review","needs-tester-signoff"]'
assert_matrix "T4" "$T4"                     skip  skip  skip  wake  wake  labeled
assert_matrix "T4" "$T4"                     wake  wake  wake  wake  wake  merged

# ----------------------------------------------------------------------------
# Transition 5 — both reviews done, all wake-trigger labels removed BEFORE
# merge (label-cleanup.yml ADR-0007 path). PR carries only lifecycle labels.
# Expected (labeled): nobody wakes via labels (helper is state-agnostic by
# design; query_pr_labeled's --state open filter is the *integration*-level
# guard for closed PRs, exercised by doctor --fanout — d211 §S4-PR-Open-4
# documents the contract).
# Expected (merged): default fanout (orch/PM/dev) wakes for post-merge work;
# architect/tester skip because labels were cleaned pre-merge.
# ----------------------------------------------------------------------------
echo ""
echo "=== T5: reviews complete, wake labels cleaned (pre-merge state) ==="
T5='["type:feature","priority:P2"]'
assert_matrix "T5" "$T5"                     skip  skip  skip  skip  skip  labeled
assert_matrix "T5" "$T5"                     wake  wake  wake  skip  skip  merged

# ----------------------------------------------------------------------------
# Cross-cutting: kill-switch sanity for the lifecycle. If PR_LABELED_FANOUT
# is emptied mid-flight (operator kill-switch per ADR-0009 § 6), NO label-gate
# wake fires at any transition, even when T4 has both wake labels.
# (BUG-1-class regression guard at the integration level — d211 §Test 12
# covers the helper-level, this covers the lifecycle-level.)
# ----------------------------------------------------------------------------
echo ""
echo "=== X1: PR_LABELED_FANOUT='' kill switch over the whole lifecycle ==="
SAVED_FANOUT="$PR_LABELED_FANOUT"
PR_LABELED_FANOUT=""
for tname_labels in "T1:$T1" "T2:$T2" "T3:$T3" "T4:$T4" "T5:$T5"; do
  tname="${tname_labels%%:*}"
  lab="${tname_labels#*:}"
  for role in architect tester; do
    got=$(wake_state_labeled "$role" "$lab")
    check "[X1/$tname] $role SKIPS (PR_LABELED_FANOUT empty)" "skip" "$got"
  done
done
PR_LABELED_FANOUT="$SAVED_FANOUT"

echo ""
echo "======================================"
echo "PASS=$PASS  FAIL=$FAIL"
echo "======================================"
[ "$FAIL" -eq 0 ]
