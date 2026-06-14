# ADR-0012 — Required Label Set on Issue/PR Creation

**Status:** Accepted
**Date:** 2026-06-14
**Supersedes:** —
**Related:** ADR-0002 (GitHub-Native Autonomy), ADR-0007 (Label Cleanup), ADR-0009 (Label Discipline), ADR-0013 (Status → Board Sync)

---

## Context

The dev-studio template defines four label categories that together encode
everything the autonomy loop and the human owner need to know about a piece
of work:

| Category | Examples | Purpose |
|---|---|---|
| `type:*` | `type:vision`, `type:feature`, `type:bug`, `type:docs`, `type:chore`, `type:refactor`, `type:incident` | What kind of work this is |
| `status:*` | `status:backlog`, `status:ready`, `status:in-progress`, `status:in-review`, `status:blocked`, `status:done` | Where in the flow it lives |
| `agent:*` | `agent:product-manager`, `agent:architect`, `agent:developer`, `agent:tester`, `agent:orchestrator`, `agent:human` | Who owns it |
| `cc:*` | `cc:product-manager`, `cc:architect`, `cc:developer`, `cc:tester`, `cc:orchestrator` | Who holds the active queue / next ball |

ADR-0009 codified the **handoff** discipline (when to flip `cc:*`), but it
did not codify the **birth** discipline: which labels must be present the
moment an issue or PR is *first* created. In practice we have observed
agents creating issues with only the `agent:*` + `cc:*` pair, leaving
`type:*` and `status:*` missing. Concrete failure observed on
2026-06-14 in the first `AtilCalculator` bootstrap:

- Issue #2 (PM-authored `docs(product): vision + personas`) had only
  `agent:human`, `cc:tester`, `needs-tester-signoff` — no `type:*`, no
  `status:*`. Board card landed in the "No Status" lane and the human
  could not filter the work by kind.
- Issue #3 (Architect-authored `ADR-0001`) had `type:feature` +
  `status:backlog` + `agent:architect` + `cc:architect` — correct, but
  the board Status field was still empty because GitHub does not sync
  the `status:*` label to the Projects v2 Status field automatically
  (see ADR-0013).

The agent soul docs already show example `gh issue create` /
`gh pr create` commands, but those examples only carry one or two
labels each, which has trained the agents to treat the rest as
optional.

## Decision

**Every issue and every PR opened by an agent — at the moment of
creation — MUST carry at least one label from each of the four
categories**: `type:*`, `status:*`, `agent:*`, `cc:*`. There is no
exception for "I'll add it later" or "the orchestrator will set
this." Missing categories at birth break two systems at once:

1. **Board hygiene** — type/status are how humans slice the backlog
   and how board automation rules (ADR-0013) decide which Status field
   value to set.
2. **Autonomy loop** — `agent:*` is the wake-up signal for `issue_assigned`
   and `cc:*` is the wake-up signal for queue position. Without both,
   the wrong agent gets woken or no agent wakes at all.

### Required-set table by event

| Event | `type:*` | `status:*` | `agent:*` | `cc:*` |
|---|---|---|---|---|
| New story issue (PM) | `type:feature` (or `type:bug`, etc.) | `status:backlog` (always at birth) | `agent:<next-owner>` | `cc:<next-owner>` |
| New design / ADR PR (Architect) | `type:docs` (ADR) or `type:refactor` (design impact) | `status:in-review` (PR is open) | `agent:architect` | `cc:product-manager`, `cc:developer` (paralel review) |
| New implementation PR (Developer) | `type:feature` / `type:bug` / `type:refactor` (match story) | `status:in-review` | `agent:developer` | `cc:tester`, plus `needs-tester-signoff` |
| New test-plan PR (Tester) | `type:docs` (test plan) or `type:feature` (test suite that ships) | `status:in-review` | `agent:tester` | `cc:developer` |
| New bug issue (Tester) | `type:bug` | `status:backlog` | `agent:developer` | `cc:developer` |
| New chore / refactor issue (any agent) | `type:chore` or `type:refactor` | `status:backlog` | `agent:<owner>` | `cc:<owner>` |
| Sprint-coordination issue (Orchestrator) | `type:chore` | `status:ready` (immediately actionable) | `agent:orchestrator` | `cc:<addressee>` |
| Incident issue (any agent) | `type:incident` | `status:in-progress` | `agent:developer` | `cc:developer`, `cc:architect` |

If an agent legitimately cannot decide a category (e.g. type is
ambiguous), the contract is **escalate, do not omit**: add a comment
asking the relevant owner to relabel, but ship the issue with a
best-guess label so the four-category invariant holds.

### Enforcement

Documentation alone is not enough — agents have already proven they
will skip steps under time pressure. Therefore this ADR is shipped
alongside two GitHub Actions workflows:

1. **`label-check.yml`** (this ADR). On every issue/PR `opened`,
   `reopened`, `labeled`, `unlabeled` event, the workflow verifies
   that all four categories have at least one label. If any are
   missing, the workflow:
   - posts an inline comment listing exactly which categories are
     missing,
   - fails the check (visible in the PR "Checks" UI),
   - re-fires on every subsequent label change so the agent fix-back
     loop can drive it green.
2. **`status-label-to-board.yml`** (ADR-0013). Mirrors `status:*`
   label changes onto the Projects v2 Status field so the board no
   longer drifts from labels.

### Examples for each agent (canonical `gh` commands)

PM creating a vision-derived PR:

```bash
gh pr create \
  --title "docs(product): vision + personas (intake #<N>)" \
  --body "Closes #<N>'s vision intake..." \
  --label "type:docs" \
  --label "status:in-review" \
  --label "agent:human" \
  --label "cc:architect"
```

PM creating a story issue:

```bash
gh issue create \
  --title "STORY-NNN: <one-liner>" \
  --body "..." \
  --label "type:feature" \
  --label "status:backlog" \
  --label "agent:tester" \
  --label "cc:tester"
```

Architect creating an ADR PR:

```bash
gh pr create \
  --title "docs(adr): ADR-NNNN <slug>" \
  --body "Proposes <decision>..." \
  --label "type:docs" \
  --label "status:in-review" \
  --label "agent:architect" \
  --label "cc:product-manager" \
  --label "cc:developer"
```

Developer opening an implementation PR (draft):

```bash
gh pr create --draft \
  --title "feat(scope): STORY-NNN <one-liner>" \
  --body "Implements STORY-NNN..." \
  --label "type:feature" \
  --label "status:in-review" \
  --label "agent:developer" \
  --label "cc:tester" \
  --label "needs-tester-signoff"
```

Tester filing a bug issue:

```bash
gh issue create \
  --title "BUG: <one-liner>" \
  --body "Repro steps..." \
  --label "type:bug" \
  --label "status:backlog" \
  --label "agent:developer" \
  --label "cc:developer" \
  --label "priority:P1"
```

Orchestrator opening a sprint-coordination issue:

```bash
gh issue create \
  --title "Sprint N kickoff" \
  --body "Plan..." \
  --label "type:chore" \
  --label "status:ready" \
  --label "agent:orchestrator" \
  --label "cc:product-manager"
```

## Consequences

### Positive

- Every artifact carries enough metadata for the autonomy loop and
  the human owner to act on it from the first second.
- Board lanes are never "No Status" again (combined with ADR-0013).
- The `label-check` workflow turns a soft norm into a CI gate, which
  matches how every other discipline gate (tests, lint, CI green)
  works in this template.
- Future agent roles (we may add `agent:designer`, `agent:devops`
  later) inherit the same contract for free.

### Negative

- Agents must remember more parameters at creation time. Mitigation:
  every soul doc now contains the canonical `gh` command for the
  agent's most common create flows.
- One more CI workflow to maintain. Mitigation: `label-check.yml` is
  ~80 lines and uses only the GitHub Actions `actions/github-script@v7`
  primitive — no third-party deps.
- Issues created via the GitHub web UI by humans may initially miss
  labels. Mitigation: the same `label-check` workflow comments with
  exact missing labels, and the human can fix in one click; the
  template's GUI issue templates also pre-fill the labels.

### Out of scope

- Replacing labels with a typed enum field on the Projects v2 board.
  Considered, rejected: GitHub Actions on label change is universally
  reliable; field-update events are not.
- Auto-fixing missing labels via the workflow. Considered, rejected:
  the agent should learn to set labels at birth; auto-fix hides the
  defect.

## Future work

- Add `priority:*` to the required-set (currently optional). Likely
  to follow once agents are stable on the four-category baseline.
- Extend `label-check.yml` to verify mutual exclusion in some
  categories (e.g. exactly one `status:*` at a time).
