# ADR-0016 — Issues-only Project Board

**Status:** Accepted
**Date:** 2026-06-15
**Supersedes:** ADR-0013 (board sync scope — was issues+PRs, now issues-only)
**Related:** ADR-0012 (4-cat label invariant), ADR-0013 (status → board sync), ADR-0014 (PROJECT_TOKEN secret), ADR-0015 (atomic hand-off)

---

## Context

ADR-0013 wired the Projects v2 board's Status field to `status:*` labels
via a workflow that listened on both `issues` and `pull_request_target`
`labeled|unlabeled` events. The intent was that any work item — Issue
**or** PR — would appear on the board and move through
Backlog → Ready → In Progress → In Review → Done in lock-step with its
status label.

In practice on 2026-06-15 (AtilCalculator round 4) this design exposed
two real failure modes:

### Failure 1 — `pull_request_target: labeled` does NOT fire post-merge

After a PR is merged it transitions to `closed`. GitHub's
`pull_request_target` trigger for the `labeled` action only fires while
the PR is **open**. When the orchestrator (per ADR-0015) flipped
`status:in-review` → `status:done` on PR #2 after merge, no workflow
ran, no board sync happened, and the card stayed in **In Review**
forever even though the label correctly said `status:done`. Verified:
the last `pull_request_target` run for `feat/vision-intake-1` is at
08:42Z (PR open). The merge at 08:50Z and the post-merge `status:done`
label flip produced **zero** workflow runs. The board sync silently
under-reports completion.

### Failure 2 — Duplicate cards per work item

GitHub's built-in **Project workflow #7 — "Auto-add to project"** is
enabled by default on new ProjectsV2 projects. It auto-cards every PR
opened against the linked repository. For a single work item the user
ends up with two cards on the board: one Issue card (tracking the
work) and one PR card (tracking the delivery vehicle). They diverge in
status (Issue gets `status:in-progress` when picked up; PR gets
`status:in-review` on open) and the human reader has to mentally
reconcile them.

### Why this wasn't caught earlier

ADR-0013 was tested only on the **opening** half of the PR lifecycle.
Round 4 was the first end-to-end run where a PR was actually merged
and the orchestrator's post-merge cleanup (ADR-0015) attempted to set
`status:done`. The trigger gap is a GitHub platform behaviour, not a
bug in our workflow code.

## Decision

**The Projects v2 board mirrors Issues only. Pull requests are NOT
board items.** PRs remain tracked via GitHub's native PR view and via
their `Refs: #N` / `Closes: #N` link to the originating Issue. When the
Issue reaches `status:done`, the work is done — regardless of how many
PRs were used to deliver it.

### Concrete consequences

1. **`status-label-to-board.yml.tmpl`** removes the
   `pull_request_target` trigger and the `pull-requests: read`
   permission. The script body's `isPR` branch becomes a defensive
   no-op guard.
2. **The GitHub-native project workflow "Auto-add to project"** is
   **disabled** at bootstrap time (manual GUI step per
   `TEMPLATE-README.md` §4 — Projects v2 workflow toggles have no
   public API per community discussion #194509).
3. **The GitHub-native project workflow "Pull request merged →
   Done"** is **disabled / left off** (same place). PR merge does
   not set an Issue's status; the agent pipeline does that via the
   Issue's `status:done` label per ADR-0015.
4. **The "Item closed → Done" project workflow stays enabled** —
   when an Issue is closed it lands in Done. This is the canonical
   "work item finished" signal.

### Hand-off implications (interacts with ADR-0015)

ADR-0015 atomic hand-off operates **on the Issue**, not the PR.
When a PR merges:
- The merge itself is a GitHub event with no board side-effect.
- The orchestrator's post-merge ritual flips the **linked Issue**'s
  `status:in-review` → `status:done` and removes `agent:*` / `cc:*`
  for any roles that have completed their turn.
- The board sync workflow runs on the **Issue** event (still triggers
  fine post-merge because closing an Issue is a separate `issues`
  event from labeling a PR) and moves the Issue card to Done.

### What about PR review state?

PRs still need to be visible to reviewers. GitHub's native PR list
already does this well: filter by `is:open is:pr`, sort by
`review-requested:<user>`, etc. The board does not need to be the
single pane for PR review queue — that's a different concern.

## Consequences

### Positive
- **Single source of truth** for "what work is done": Issue
  `status:done`. No more reconciling Issue card vs PR card.
- **Fewer cards on the board** — only real work items, not delivery
  vehicles. Sprint capacity reading becomes accurate.
- **No silent failures** from the `pull_request_target: labeled`
  post-merge gap. The class of bug is removed, not patched around.
- **PR creation cost drops** — opening a draft PR for early CI does
  not pollute the board. Agents can open exploratory PRs freely.

### Negative
- **PR-only deliveries** (e.g. pure docs PRs with no tracking Issue)
  do not appear on the board. Mitigation: such PRs should reference
  an Issue (`Refs: #N`) or create a minimal `type:chore` Issue first.
  The bootstrap process treats Issues as the unit of work; PR-only
  flow is the exception, not the rule.
- **Loss of "open PR" visibility on board** — reviewers can no longer
  glance at the board to see what's awaiting review. Mitigation: this
  was already weakly captured by the `status:in-review` PR cards;
  reviewers should use GitHub's PR list. A future enhancement could
  surface an Issue's `status:in-review` on board when its linked PR
  is open.

### Neutral
- ADR-0013's status-label → board-option mapping is unchanged.
- ADR-0015's atomic hand-off invariant is unchanged.
- Agent role prompts that say "after merging your PR, set the linked
  issue's `status:done`" continue to work — the merge is the action,
  the Issue is the target.

## Implementation

This ADR is shipped together with:
1. `.github/workflows/status-label-to-board.yml.tmpl` — remove
   `pull_request_target` trigger and `pull-requests: read` permission,
   guard `isPR` path.
2. `TEMPLATE-README.md` §4 — flip the manual board-setup checklist:
   "Auto-add to project" → Disable, "Pull request merged" →
   Disable / leave off, "Item closed" stays Enable.
3. `.github/ISSUE_TEMPLATE/*.yml` — 5 templates audited for the
   4-category invariant (ADR-0012); each now ships with a
   `cc:<role>` so agent wake-up via `agent-watch.sh` works on first
   submit.

No new code in `scripts/`; no change to `agent-watch.sh` or
`bootstrap-project-board.sh`. The fix is configuration + one workflow
trigger removal.

## Verification

A fresh-project bootstrap will be considered ADR-0016-compliant when:
- Opening a draft PR against the bootstrapped repo does **not**
  create a board card.
- Merging a PR linked to an Issue (`Closes: #N`) drives the **Issue**
  card to Done (via the agent pipeline + `status:done` label on the
  Issue + `issues: closed` event firing the board-sync workflow).
- The board's card count equals the open-Issue count, not
  open-Issues + open-PRs.

## References

- ADR-0013 (status-label-to-board sync, scope was issues+PRs)
- ADR-0014 (PROJECT_TOKEN secret provisioning)
- ADR-0015 (atomic agent hand-off)
- GitHub community discussion #194509 (Projects v2 workflow API
  limitation)
- AtilCalculator round 4, PR #2 merge at 2026-06-15T08:50:07Z (the
  reproduction case for failure mode 1)
