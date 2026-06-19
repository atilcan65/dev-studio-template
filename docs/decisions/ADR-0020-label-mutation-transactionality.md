# ADR-0020 — Label-Mutation Transactionality (atomic CLI wrapper + CI gate)

**Status:** Accepted (originally accepted in AtilCalculator via PR #62, 2026-06-18T13:47:39Z, merged by @atilcan65)
**Date:** 2026-06-18 (AtilCalculator) / 2026-06-19 (template-port)
**Supersedes:** —
**Related:** ADR-0009 (label discipline), ADR-0012 (4-cat label invariant), ADR-0015 (atomic handoff), TD-004 / TD-006 / TD-008 family

**Template-port note:** This ADR was originally authored in AtilCalculator's `docs/decisions/`. It is generalized here for any project bootstrapped from dev-studio-template. The doctrine (TD-004/TD-006/TD-008 family, atomic CLI wrapper, CI gate) applies universally; only the project-specific references (issue numbers, repo URLs) need substitution.

---

## Context

The dev-studio autonomy loop depends on every issue/PR carrying one label from each of four categories at every moment (ADR-0012). The atomic hand-off micro-protocol (ADR-0015) preserves the invariant **during** transitions — but the underlying CLI primitive, `gh issue edit` / `gh pr edit`, is **non-transactional**. Three observed failure modes form a single root-cause family:

| ID | Symptom | Mechanism |
|---|---|---|
| **TD-004** | Label flip appears to succeed (no exit code, only PR URL echoed) but the labels were never changed. Caught 12 min later via stale_cc watchdog. | `gh pr edit --add-label X --remove-label Y --remove-label Z` in a single invocation may fail silently. No success/error distinction in output. |
| **TD-006** | Orchestrator's hygiene script bulk-removes `cc:orchestrator` and accidentally hits architect's `cc:architect` + `needs-architect-review` (set 8 minutes earlier). | `gh pr edit --remove-label X` does not isolate label changes per invocation. Multi-actor concurrent edits in same transaction = non-selective spread. |
| **TD-008** | Two separate `gh pr edit --remove-label` calls return success; verification shows **4 labels removed** (the 2 requested + 2 unrelated) and **1 added** (not requested). | Either `gh pr edit` does not isolate per invocation, OR another agent's automation raced between the calls, OR label-check workflow auto-cleaned unreferenced labels. Root cause unconfirmed. |

All three share one structural gap: **`gh edit` is a non-transactional primitive**. The current discipline relies on agents following the per-flip verification pattern (`gh view --json labels` after every flip — process note in `docs/tech-debt.md` §Process notes). This is **operator discipline**, not a **system invariant**. Operator discipline fails under time pressure, parallel-agent contention, and script automation.

## Decision

**Every label-mutation operation MUST be wrapped in a transactional CLI primitive.** The wrapper enforces the four-phase pattern: **read pre-state → compute diff → apply → verify → rollback on mismatch**. Manual `gh issue edit` / `gh pr edit` for label operations is **forbidden** in agent-issued commands.

### The wrapper: `scripts/atomic-label-edit.sh`

```bash
# Canonical invocation form
scripts/atomic-label-edit.sh <issue|pr> <N> \
  --expect "agent:architect" \
  --add "cc:tester" \
  --remove "cc:architect" \
  --remove "needs-architect-review"
```

The script executes four phases atomically (best-effort; see "Failure modes" below):

1. **Read pre-state** via `gh <issue|pr> view N --json labels`.
2. **Compute diff** = expected post-state = pre-state ∪ {add set} ∖ {remove set}.
3. **Apply** one label at a time via separate `gh edit` calls, verifying after each.
4. **Verify** post-state matches expected. On mismatch → rollback (re-apply removed labels, remove added labels) and exit non-zero with a clear error message.

### Why one-at-a-time `--add-label` / `--remove-label` calls (not batched)

`gh pr edit --add-label X --remove-label Y` in one invocation is the **failure mode we are defending against** (TD-004 family). Each label operation gets its own `gh edit` call + post-call verification. Cost: ~2x more API calls per flip. Benefit: TD-004 / TD-008 silent failures are detected at the call boundary, not minutes later via watchdog.

### Expected-state declaration

The `--expect` flag is a **pre-condition**: the script verifies the pre-state contains the expected labels before applying the diff. This catches the "stale snapshot" failure mode where an agent computed its diff against a labels-set that's already drifted by a peer's edit. If the expected labels aren't present, the script exits non-zero with a "pre-state drift detected" error.

### The CI gate: `.github/workflows/label-tx.yml`

Every `labeled` / `unlabeled` event on an issue/PR fires a new workflow that:

1. Reads the issue/PR label set **before** the event (from the PR comment ledger, see below).
2. Compares to the **expected** next-state (computed from the previous state + the new label event).
3. If the actual next-state matches expected → silent pass.
4. If the actual next-state does **not** match expected → post an inline comment naming the unexpected labels + who triggered them + the workflow that auto-cleaned them.

The "PR comment ledger" is a per-PR comment that the `atomic-label-edit.sh` wrapper writes on each successful transaction, recording `{timestamp, actor, pre-state, post-state}`. The workflow reads the most recent ledger entry to compute expected next-state.

### Failure modes the wrapper handles

| Failure | Detection | Response |
|---|---|---|
| `gh edit` silent no-op (TD-004) | Post-call `gh view --json labels` shows expected label not added/removed | Retry once; on second failure, rollback + exit non-zero |
| Cross-role spread (TD-006) | Pre-state contains labels not in the diff scope (e.g., other actors' `cc:*`) | Exit non-zero BEFORE applying; force agent to confirm scope |
| Over-removal (TD-008) | Post-call state shows labels removed that were NOT in the remove set | Rollback (re-add the over-removed labels) + exit non-zero |
| Pre-state drift | `--expect` labels not present in pre-state | Exit non-zero; agent must re-read + re-decide |

### Failure modes the wrapper does NOT handle (and why)

- **Concurrent edits between two agents**: if both call the wrapper simultaneously, the diff computation is based on each caller's pre-state snapshot. The second caller overwrites the first. Mitigation: agents MUST serialize label edits within a single PR (this is a process discipline; the wrapper logs a warning if it detects recent-write timestamps within 5s).
- **Workflow auto-cleanup** (label-check.yml ADR-0012 removing unreferenced labels): the wrapper cannot prevent this; the CI gate catches the unexpected post-state and surfaces it.

## Rationale

The alternative is **process discipline alone** — every agent must remember to verify after every flip, never batch operations, always read pre-state. TD-004 / TD-006 / TD-008 demonstrate that this fails in practice (5+ observed incidents in 24 hours of Sprint 1). The cost of a wrapper (one bash script + one CI workflow) is bounded; the cost of recurring incidents is unbounded (PR cycle stalls, watchdog spam, trust cost).

We are not adding a new tool because we can — we are adding it because **the underlying primitive is unsafe**. `gh edit` lacks the four properties we need (atomicity, isolation, verification, rollback). Adding them at a wrapper layer is the minimum-change path that gives us those properties without forking `gh`.

Boring tech wins (per architect heuristics): bash + `gh` CLI + GitHub Actions is the most boring possible stack. No new dependencies. No new auth surface. The wrapper script is ~80 lines; the CI workflow is ~50 lines.

## Consequences

### Positive

- TD-004 / TD-006 / TD-008 class incidents become structurally impossible (or detected at operation time, not 12 min later).
- Watchdog can be de-tuned (longer stale_cc threshold) because the system invariant replaces operator vigilance.
- New agent roles inherit label discipline for free (they call the wrapper, not raw `gh edit`).
- The CI gate provides an audit trail of every label transition (PR comment ledger).

### Negative

- **Tooling maintenance burden**: ~80-line bash script + ~50-line workflow. Test coverage required (3 scenarios: normal flip, silent failure detection, over-removal detection).
- **CI workflow change**: `.github/workflows/label-tx.yml` is human-only territory (per `.claude/CLAUDE.md` §File ownership matrix). Architect proposes, owner applies.
- **Agent discipline shift**: every agent soul doc must be updated to reference the wrapper instead of raw `gh edit`. Five soul docs touched (orchestrator, architect, developer, tester, PM).
- **API rate limit**: 2x more `gh` API calls per flip. For a project with ~50 label flips per sprint, this is negligible (well below the 5000/hour authenticated limit).

### Out of scope (this ADR)

- Replacing labels with a typed enum field on the Projects v2 board (same as ADR-0012 out-of-scope).
- A `libgh` Python library that wraps the CLI (considered; rejected: bash is the boring choice; Python adds a dependency).
- General label taxonomy redesign (separate ADR if needed).

### Follow-up tickets (template-port: file in your project when adopting)

1. `@architect` (your project): draft `scripts/atomic-label-edit.sh` skeleton (in this repo or follow-up).
2. `@architect`: draft `.github/workflows/label-tx.yml` YAML shape (design sketch for owner; per CLAUDE.md owner applies).
3. `@architect`: propose 5-row soul doc amendment text (orchestrator / architect / developer / tester / PM).
4. `@developer`: implement the bash script + workflow.
5. `@tester`: author d009 atomic-label-edit test suite (3 scenarios from §Failure modes table).
6. `@orchestrator`: amend `scripts/agent-watch.sh` watchdog to suppress stale_cc fires on type:docs PRs (sister-pattern to ADR-0021).

## Future work

- **Pre-merge dry-run**: `--dry-run` flag that computes the diff and prints expected post-state without applying. Useful for agents debugging multi-label transitions.
- **Concurrency control**: file-lock per (issue, pr) for serializing concurrent wrapper calls. Not needed for MVP-1 (agents operate sequentially on the same PR); revisit if concurrent label edits become routine.
- **Bulk operations**: `--bulk-from-file` for board hygiene scripts (orchestrator's merge-cleanup). Out of scope for MVP-1; the orchestrator's hygiene script is the primary use case.

---

**Sister ADR:** ADR-0021 (docs PR convention) — closes the docs-PR subclass of TD-006 spam via a different mechanism (peer cc:* discipline, not wrapper tooling).
