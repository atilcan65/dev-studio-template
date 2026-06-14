# ADR-0015 — Atomic Agent Hand-off (preserve 4-category invariant)

**Status:** Accepted
**Date:** 2026-06-14
**Supersedes:** —
**Related:** ADR-0009 (label discipline), ADR-0012 (4-cat label invariant), ADR-0013 (status → board sync), ADR-0014 (PROJECT_TOKEN secret)

---

## Context

ADR-0012 requires every issue and PR to carry one label from each of four
categories — `type:*`, `status:*`, `agent:*`, `cc:*` — at **every moment**
of its lifecycle, not only at birth. The Label Check workflow runs on
every `labeled` and `unlabeled` event and fails the check if any of the
four is missing.

ADR-0009 codified the `cc:*` flip ("ball-in-court" semantic), but it left
the `agent:*` transition implicit. In practice, agents who finish their
turn have been **removing** their own `agent:<self>` label and only
**adding** the next role's `cc:<next>`. Concrete failure observed on
2026-06-14 during AtilCalculator bootstrap round 2:

```
2026-06-14T19:36:37 Issue #1 labels: type:vision, status:backlog, cc:product-manager
Present per category: {"type:":["type:vision"],"status:":["status:backlog"],"agent:":[],"cc:":["cc:product-manager"]}
##[error]Issue #1 missing required label category: agent:*
```

Root cause: `.claude/agents/product-manager.md.tmpl` line 128 instructs
PM to **remove** `agent:product-manager` and **add** `cc:product-manager`
when Vision intake completes — leaving `agent:*` empty until the next
agent (orchestrator → architect) picks it up. During the gap, the Label
Check workflow correctly raises a missing-category error.

The same anti-pattern lives implicitly in every agent's "I'm done"
ritual: developer finishing implementation, tester finishing test plan,
architect finishing ADR. We only caught PM's first because Vision is
the very first event in any project's life.

## Decision

**Every agent role-transition must be atomic from the perspective of
the 4-category invariant**: the next `agent:*` label is added **before**
the current `agent:*` label is removed.

### Universal hand-off micro-protocol

When agent `<self>` finishes its turn on issue/PR `N` and hand-off goes
to `<next>`:

1. **Add** `agent:<next>` ← invariant kept (now two `agent:*` momentarily)
2. **Add** `cc:<next>` ← queue flip
3. **Remove** `cc:<self>` ← clear ball-in-court
4. **Remove** `agent:<self>` ← invariant kept (now one `agent:*` again)

The two `add` operations must precede the two `remove` operations. The
two adds are commutative (order doesn't matter); same for removes. CLI:

```bash
gh issue edit N \
  --add-label "agent:<next>" \
  --add-label "cc:<next>" \
  --remove-label "cc:<self>" \
  --remove-label "agent:<self>"
```

`gh` processes label arguments left-to-right against the GitHub API, so
the `--add-label` flags applied first. Even if the API processed them
in parallel, the steady state during overlap is `agent:<self> + agent:<next>`
— still passing the 4-category check.

### Why two `agent:*` labels overlap is safe

ADR-0012 Label Check requires **at least one** label per category, not
**exactly one**. The check uses `present[prefix].length > 0`. Two
`agent:*` labels during the overlap window are acceptable. The
human-facing "who owns this?" question is answered by `cc:*`, which
is enforced as mutually exclusive (single owner queue).

### What about the "I'm finished forever" terminal case?

When work moves to a terminal state (Done, closed), the orchestrator
clears both `agent:*` and `cc:*` and adds `status:done` — see
`agents/orchestrator.md.tmpl` line 81. This bypass is **only** allowed
for terminal states. ADR-0012 Label Check ignores closed issues
(see workflow `on: issues: types: [opened, labeled, unlabeled, reopened]`).

### Hand-off chains (canonical)

| From | Trigger | To | Rationale |
|---|---|---|---|
| PM (Vision intake done) | docs PR opened | `agent:human` | Human reviews vision PR; merge unblocks orchestrator |
| PM (story written) | issue created with AC | `agent:tester` (or architect if design unclear) | Tester writes test plan first |
| Architect (ADR drafted) | PR opened | `agent:human` | Human reviews/merges ADR |
| Tester (test plan ready) | PR merged | `agent:developer` | TDD red phase ready |
| Developer (PR opened) | tests pass, `needs-tester-signoff` set | `agent:tester` | Tester signoff |
| Tester (APPROVED) | comment + verdict | `agent:human` (via `status:ready`) | Human merges |
| Any (question/blocker) | comment with mention | `agent:<resolver>` | Sender keeps `cc:<self>` until answered |

### Enforcement

1. **Soul docs updated** — every agent's soul file (`.claude/agents/*.md.tmpl`)
   replaces non-atomic flips with the 4-flag `gh issue edit` form.
2. **CLAUDE.md.tmpl updated** — §Handoff Label Discipline now lists the
   universal 4-step micro-protocol with the `--add-label agent:<next>`
   line included explicitly.
3. **No CI gate** — Label Check (ADR-0012) already enforces the
   invariant. Atomic hand-off makes it pass during transitions instead
   of flickering red-green-red.

## Consequences

**Positive:**
- ADR-0012 Label Check stops false-failing on hand-off events.
- No more spurious "missing agent:*" comments on issues mid-flow.
- Agents have a single, copy-paste-able hand-off command instead of
  remembering which label to flip in which order.
- Multi-agent coordination remains race-free: even if two label-change
  events arrive within milliseconds, the 4-category invariant holds.

**Negative:**
- Brief window (typically <500ms) where issue has two `agent:*` labels.
  Cosmetically odd in the GitHub UI; functionally fine. Mitigation:
  none required — overlap window is shorter than human reaction time.

**Future work:**
- ADR-0009 superseded in part (cc-only flip is incomplete; atomic 4-flag
  form is canonical).
- Consider a `scripts/handoff.sh <issue> <next-role>` helper that wraps
  the 4-flag form so agents have less ceremony.
