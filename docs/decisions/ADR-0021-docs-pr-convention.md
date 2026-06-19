# ADR-0021 — Docs PR Convention (default `agent:<author>` only; peer `cc:*` requires cross-cutting rationale)

**Status:** Accepted (originally accepted in AtilCalculator via PR #62, 2026-06-18T13:47:39Z, merged by @atilcan65)
**Date:** 2026-06-18 (AtilCalculator) / 2026-06-19 (template-port)
**Supersedes:** —
**Related:** ADR-0009 (label discipline), ADR-0012 (4-cat label invariant), ADR-0015 (atomic handoff), ADR-0020 (label-mutation transactionality), TD-006, Issue #46 (short-term doctrine amendment)

**Template-port note:** This ADR was originally authored in AtilCalculator's `docs/decisions/`. It is generalized here for any project bootstrapped from dev-studio-template. The convention (`## Peer review rationale` section, status flip matrix) applies universally; only the project-specific references (PR numbers, issue numbers) need substitution.

---

## Context

`type:docs` PRs are **self-contained**: they modify documentation only (`docs/**`, `CHANGELOG.md`, ADR/design/tech-debt files), have no runtime impact, and require **no peer code review** (no test surface, no production behavior change). Yet agents have reflexively added peer `cc:*` labels to docs PRs at creation time, triggering the stale_cc watchdog spam observed in TD-006 + Issue #46:

| PR | Author | Peer `cc:*` added | Outcome |
|---|---|---|---|
| PR #33 | @architect (ADR-0019) | `cc:tester`, `cc:developer` | No peer review pass; peer cc pruned by orchestrator; architect re-added; watchdog fired |
| PR #36 | @architect (STORY-005 design) | `cc:product-manager`, `cc:developer` | Same pattern; multiple stale_cc wakes over days |
| PR #39 | @architect (TD-005/006/007 tech-debt) | `cc:orchestrator` | Orchestrator added then removed (TD-006 subclass); architect's cc:architect stayed |
| PR #61 | @architect (TD-009 → Resolved) | `cc:orchestrator`, `cc:developer`, `cc:tester` | All three pruned during sprint close-out; no peer review happened |

In **none** of these cases did a peer actually review the docs PR. The peer `cc:*` labels served as **social courtesy**, not as workflow signals. The watchdog correctly interpreted them as "peer verdict expected"; when no verdict came, it fired stale_cc wakes — generating queue noise without any actual review happening.

This is a **TD-006 subclass**: TD-006 documents the bulk-hygiene mechanism; this ADR documents the **convention that prevents the mechanism from being needed** on the most common (docs) PR class.

## Decision

**`type:docs` PRs default to `agent:<author>` only.** Peer `cc:*` labels are added **only when the PR body explicitly documents a cross-cutting concern requiring peer input**. This applies to all `type:docs` PRs at creation time.

### Peer `cc:*` is required (not optional) when

1. **PR body contains a `## Peer review rationale` section** that explains:
   - The cross-cutting concern (e.g., "this ADR amends the API contract §Observability, which the developer is implementing against").
   - What the peer is expected to verify (e.g., "verify the d007 regex amendment matches the new `EngineError` subclass").
   - Time bound for the peer verdict (e.g., "verdict expected within 24h, or pre-Sprint-2 planning").

2. **The PR is not pure-doc**: e.g., it also touches `src/`, `tests/`, `scripts/`, `.github/workflows/`. In that case it should be `type:refactor` or `type:feature` with docs as a sub-deliverable, not `type:docs`.

### Peer `cc:*` is forbidden when

- The PR is purely documentation (ADR amendment, design doc, tech-debt log update, CHANGELOG entry, runbook).
- The peer is added "for awareness" without an explicit cross-cutting concern.
- The peer `cc:*` is added to mirror the author's `agent:*` (e.g., author adds `cc:developer` to their own PR "because developer might be interested").

### PR body convention

When peer `cc:*` is added, the PR body MUST include:

```markdown
## Peer review rationale

**Peer**: @<role>
**Cross-cutting concern**: <one sentence>
**What peer verifies**: <one sentence>
**Time bound**: <"verdict by <date>" or "before <event>">
```

Without this section, the PR is not eligible for peer `cc:*`. Agents that add peer `cc:*` without the section MUST remove them before opening the PR (per the wrapper-or-direct discipline — see ADR-0020).

### Watchdog amendment

`scripts/agent-watch.sh` MUST be amended to **suppress stale_cc wakes** on `type:docs` PRs that lack the `## Peer review rationale` section in the PR body. The watchdog's stale_cc check is bypassed when:

```bash
if pr_has_label "$N" "type:docs" && ! pr_body_has_section "$N" "## Peer review rationale"; then
  log_debug "stale_cc suppressed: docs PR without peer review rationale"
  return 0  # no wake
fi
```

This is the **short-term** spam-killer that Issue #46 asks for; this ADR formalizes it as permanent doctrine.

### Status flip responsibility matrix (doctrine amendment per ADR-0025)

The peer review chain produces a verdict (APPROVED / NEEDS CHANGES) in PR comments and in `gh pr review` events. The PR's `status:*` label MUST be flipped to `status:ready` once the verdict is "complete from a queue-position standpoint" — but the **agent responsible for the flip** depends on the PR type and the active reviewer chain.

| PR type | Status flip responsibility | Trigger condition |
|---|---|---|
| `type:feature`, `type:refactor`, `type:bug` | The peer tester (`agent:tester`) | After `tester` posts APPROVE in PR comments OR `gh pr review --approve` (per TD-010; flip in same atomic transition) |
| `type:chore` | The peer tester (if `cc:tester` is set) OR the sole `cc:*` holder (if no tester in chain) | Same: after the relevant peer's APPROVE |
| `type:docs` (default: `agent:<author>` only) | The sole `cc:*` holder (typically `cc:orchestrator` for board hygiene) | After ≥1 peer APPROVE comment in PR comments AND no CHANGES_REQUESTED comment outstanding |
| `type:incident` | The peer orchestrator (`cc:orchestrator`) | After orchestrator's APPROVE; incident PRs bypass the tester chain (per ADR-0009 §Incident handling) |
| Any type with no peer `cc:*` AND no `verdict-by:<ts>` | The PR author (`agent:<author>`) | After self-verifying that the change is merge-ready; for self-merge of trivial edits (typo fixes, version bumps) |

**Atomic transition (per ADR-0015)**:

```bash
gh pr edit N \
  --remove-label status:in-review \
  --add-label status:ready
```

This is a single atomic `gh pr edit` invocation; do NOT split into multiple calls (per TD-004, TD-008). The `--remove-label` and `--add-label` flags in the same `gh pr edit` are a single transaction; verify with `gh pr view N --json labels` after the call (per TD-004 process note).

**Implementation**: the orchestrator's `agent-watch.sh` (which already sweeps the board) adds a `query_verdict_completion` function that emits a `verdict_completed:<pr#>` event when the trigger conditions for the PR's type match. On receiving the event, the responsible agent (per the matrix above) executes the atomic transition.

**Template-port note**: the matrix is expressed in terms of PR types and roles, not project-specific names. The "peer tester" is whichever role holds the `cc:tester` label on the PR; the "sole cc:* holder" is whoever currently has the queue. Lifting this convention into the dev-studio template requires no edits.

## Rationale

The root cause of the docs-PR stale_cc spam is **reflexive peer cc:* addition at PR creation**. Agents add peer `cc:*` because the 4-cat invariant requires *some* `cc:*` (per ADR-0012), and mirroring `agent:<author>` feels like a safe default. But for self-contained docs PRs, **there is no peer to mirror** — the author is the only one with skin in the game.

Three alternative conventions were considered:

| Alternative | Pros | Cons | Verdict |
|---|---|---|---|
| **A**: Allow `cc:<self>` (the author's own role) on docs PRs | Closes the 4-cat invariant immediately | Violates `cc:*` semantics ("queue position") — `cc:<self>` is meaningless (agent holds the queue for themselves by definition) | ❌ Rejected |
| **B**: No `cc:*` on docs PRs (only `agent:<author>`) | Cleanest; the 4-cat invariant is broken transiently | Breaks ADR-0012 Label Check (requires ≥1 cc:*) | ❌ Rejected (would require ADR-0012 amendment) |
| **C** (chosen): Default `agent:<author>` only; peer `cc:*` requires explicit `## Peer review rationale` section | Preserves 4-cat invariant; closes the spam; documents the convention | Slight friction (agent must consciously decide) | ✅ Adopted |

Alternative C matches the **boring tech wins** heuristic: the convention is enforceable via the existing PR body parsing in `scripts/agent-watch.sh`, requires no new tools (just a watchdog amendment), and the PR body section makes the rationale visible to humans (not buried in label semantics).

## Consequences

### Positive

- TD-006 subclass on docs PRs is **structurally prevented** (no peer `cc:*` → no stale_cc wake to fire).
- Agent reflection cost: agents must consciously decide whether the PR is genuinely cross-cutting. Self-contained docs PRs no longer trigger peer wakes.
- Watchdog can be tuned **less aggressively** (or this subclass can be removed entirely from the wake set), reducing queue noise across all roles.
- The `## Peer review rationale` section doubles as **documentation for the reviewer** — when a peer cc:* IS warranted, the rationale is already written down.

### Negative

- **Process friction**: agents must add the `## Peer review rationale` section whenever they add peer `cc:*` to a docs PR. Mitigation: the wrapper or a pre-PR script can prompt the agent for the section.
- **Subjective judgment**: "is this truly cross-cutting?" is a judgment call. Mitigation: the section forces the agent to articulate the concern, which surfaces bad calls before the peer is woken.
- **Watchdog amendment required**: `scripts/agent-watch.sh` must be updated to implement the §Watchdog amendment logic. This is a developer-owned change (orchestrator's lane if the watchdog is owned there — clarify in implementation PR).

### Out of scope (this ADR)

- Enforcing the `## Peer review rationale` section via CI gate (separate ADR; same shape as ADR-0012's label-check.yml).
- Extending the convention to `type:chore` PRs (some chores are cross-cutting, e.g., "STATUS block as action driver" affects all roles). Defer to a follow-up ADR if the spam pattern emerges for chores too.
- Replacing `cc:*` with a "review pending" field on the Projects v2 board. Considered; rejected: same reasoning as ADR-0012 out-of-scope.

### Follow-up tickets (template-port: file in your project when adopting)

1. `@architect` (your project): draft the `## Peer review rationale` section template in `docs/templates/pr-peer-review-rationale.md.tmpl` (or as a GitHub PR template).
2. `@developer` (or `@orchestrator`, depending on ownership): implement the watchdog amendment per §Watchdog amendment logic.
3. `@tester`: author d010 docs-pr-convention regression test (parse PR body + labels, assert invariant holds).
4. `@architect`: update the 5 soul docs to reference this convention (orchestrator / architect / developer / tester / PM).
5. **Issue #46 closure**: when this ADR is accepted, Issue #46's "Short-term" ACs are satisfied by the watchdog amendment. No separate chore needed.

## Future work

- **PR template**: add a `docs/pr-template.md` with the `## Peer review rationale` section pre-populated as a collapsible `<details>` block. Agents fill it in only if adding peer `cc:*`.
- **Audit dashboard**: weekly report of `type:docs` PRs with peer `cc:*` and whether the rationale section was substantive (not boilerplate). Catches convention drift.
- **Cross-cutting detection**: a linter that flags docs PRs whose body mentions cross-cutting concerns (e.g., "this changes the API contract") but lacks the rationale section. Run as a `d011` static check.

---

**Sister ADR:** ADR-0020 (label-mutation transactionality) — closes the structural TD-004/TD-006/TD-008 class via wrapper tooling. This ADR closes the docs-PR subclass of TD-006 via convention discipline.
