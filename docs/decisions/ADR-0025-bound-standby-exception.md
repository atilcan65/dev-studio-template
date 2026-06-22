# ADR-0025 — Bound Standby Exception (a) + Queue-Empty Wake (Anti-Stall Guard)

**Status:** Superseded (in template context — see Template Note below)
**Date:** 2026-06-19
**Supersedes:** —
**Related:** ADR-0002 (autonomy loop), ADR-0012 (4-cat invariant), ADR-0015 (atomic handoff), ADR-0021 (docs PR convention), ADR-0024 (stale-verdict watchdog schema), `docs/CLAUDE.md` §Things agents must NEVER do (target file for human mirror), Issue #109 (filed by peer), TD-006 family

---

## Template Note (added on port from AtilCalculator Issue #263)

This ADR is mirrored from AtilCalculator for historical reference. In the
**dev-studio-template** context it is functionally **superseded** by the
`§Doctrine Reminder — no self-standby` section that lives in the 5 soul
templates (`orchestrator.md.tmpl`, `product-manager.md.tmpl`,
`architect.md.tmpl`, `developer.md.tmpl`, `tester.md.tmpl`) and in
`.claude/CLAUDE.md.tmpl` §Things agents must NEVER do (the
"forbidden self-justified pause" enumeration). That doctrine lands via
Issue #238 / PR #40 (template) / PR #41 (template `standby` text fix).
The §Doctrine Reminder is stricter than this ADR's bound-standby
exception (it enumerates 4 forbidden modes instead of one bounded one) and
lives in code (soul templates), so a `§Doctrine Reminder` patch is the
preferred enforcement mechanism in the template.

**Do NOT mirror this ADR's bound-standby language into template soul files** —
the §Doctrine Reminder is the canonical source. This ADR stays in `docs/decisions/`
for traceability of the historical reasoning.

---

## Context

The autonomy loop's `agent-watch.sh` polls GitHub for new events every 60 seconds and dispatches them to the relevant agent. Agents process each event ("review yap, label flip et, peer'i bilgilendir, sonra standby") and idle until the next event arrives.

The observed failure mode: agents **self-extend standby indefinitely** when the work-context shifts (e.g., post-merge hygiene phase ends, but a P0 issue remains open in the agent's queue). The agent's only "standby instruction" was a one-line chat message that was contextually appropriate at the time but is no longer the binding context. Per `docs/CLAUDE.md` §Things agents must NEVER do, agents must not "invent self-imposed work pauses" — yet the standby loop, as currently implemented, makes the self-extended pause indistinguishable from a human-bounded one.

Concrete observed instance (2026-06-19): the architect agent sat in standby processing only `stale_cc` re-fires on PR #103 (a closed-loop pattern) for several hours, while a peer-assigned `agent:architect` P0 issue was open in the queue. No explicit re-confirmation of the standby was ever given in chat; the agent's "no action" responses were structurally indistinguishable from intentional standby.

This is a **doctrine gap**, not a tooling gap. The chat-level "standby" instruction was never bounded; the autonomy loop has no built-in mechanism to detect "agent is in standby + P0 work pending + no re-confirmation in chat."

The fix has two parts:
1. **Doctrine amendment**: bound the standby exception explicitly. Indefinite standby requires explicit re-confirmation.
2. **Queue-empty wake (technical complement)**: a synthetic wake when the agent's queue is empty for N consecutive polls but P0/P1 work is open. Breaks the agent out of standby automatically.

## Decision

### 1. Doctrine amendment — bound standby exception (a)

Add to `docs/CLAUDE.md` §Things agents must NEVER do as a new sub-clause under the existing "valid reasons to pause work" enumeration:

> **Standby exception (a) is bounded.** It persists only for the **current task turn** — the immediate work item the human mentioned in the most recent chat instruction. Once that work item completes (or the implicit work context shifts — e.g., post-merge hygiene ends and priority work remains), the agent returns to normal queue processing. **Indefinite standby requires an explicit re-confirmation** in the current chat thread, expressed as either:
> - `"continue standby"` (renews for one more task turn at most), or
> - `"standby until <ISO-timestamp>"` (binds to a specific time), or
> - `"standby until <event>"` (binds to a specific event the human names).
>
> Self-extension of standby without re-confirmation is an anti-pattern equivalent to "invent self-imposed work pauses." When in doubt, the agent should poll its queue (`scripts/agent-watch.sh <role>`) and act on any pending events rather than assuming the prior standby still binds.

**Target location**: `docs/CLAUDE.md` §Things agents must NEVER do, as a new sub-bullet under the "valid reasons to pause work" enumeration. This file is human-owned (per `docs/CLAUDE.md` file ownership matrix); the architect proposes the amendment via this ADR, the human mirrors the text into the canonical `docs/CLAUDE.md` on acceptance.

**Template-port note**: the doctrine language above is project-agnostic. No project-specific names appear; the convention applies to any agent operating under the autonomy loop, in any project that uses the dev-studio template. Lifting this ADR into the template requires no edits.

### 2. Queue-empty wake (anti-stall guard) — technical complement

`scripts/agent-watch.sh` adds a synthetic wake event when the following conditions hold for N consecutive polls (default N=3, ~3 minutes):

- `new_events: []` for the past N polls, AND
- The agent has at least one OPEN issue with `agent:<role>` AND (`priority:P0` OR `priority:P1`), OR an OPEN PR with `agent:<role>` AND `status:in-review` AND `needs-<role>-<action>` label.

Event kind: `queue_empty_but_priority_pending`. Event ID: `queue-empty-<role>-<bucket>` (5-minute bucket, same throttle scheme as `stale_cc` / `stale_verdict`).

Event payload:
```json
{
  "id": "queue-empty-architect-b42",
  "kind": "queue_empty_but_priority_pending",
  "number": 0,
  "title": "Queue empty for 3 polls but priority work pending",
  "url": "https://github.com/<org>/<repo>/issues?q=is%3Aopen+label%3Aagent%3Aarchitect+label%3Apriority%3AP0",
  "updated_at": "<ISO timestamp>",
  "context": {
    "role": "architect",
    "empty_polls": 3,
    "priority_items": [
      { "type": "issue", "number": 109, "title": "Doctrine amendment: bound standby exception" },
      { "type": "pr", "number": 105, "title": "STORY-009 TDD RED contract suite" }
    ],
    "note": "Queue is structurally empty of new events but priority work is open under agent:<role>. Standby exception may be misapplied; re-confirm with human or proceed with queue processing."
  }
}
```

On receiving this event, the agent:
- Polls its own queue via `scripts/agent-watch.sh <role>` (self-verification)
- If priority work is found, processes it (the standby is no longer binding)
- If priority work is NOT found (false positive), takes no action
- In both cases, the event is logged in the agent's response for audit trail

**Configuration** (env vars on `agent-watch.sh`):
- `QUEUE_EMPTY_THRESHOLD_POLLS` (default 3)
- `QUEUE_EMPTY_PRIORITY_LABEL` (default `priority:P0`, can be extended to `priority:P1` via `QUEUE_EMPTY_INCLUDE_P1=true`)

**Template-port note**: the queue-empty query uses `gh issue list` and `gh pr list` with role/priority label filters — both standard GitHub CLI surfaces, no project-specific dependencies. The `scripts/agent-watch.sh` is template-owned; lifting this feature into the template is a one-file addition.

## Rationale

The current standby doctrine is **operationally indistinguishable from "agent has nothing to do."** When `new_events: []` for several polls, the agent has no way to know whether:
- (a) the human intended indefinite standby (a valid bounded pause), or
- (b) the work context shifted and the agent should be processing queue (an unbounded pause, anti-pattern)

The chat-level "standby" instruction, as a one-line template, doesn't disambiguate. The agent defaults to the safer-seeming option (standby), but the safer-seeming option is actually the anti-pattern when priority work is open.

Three alternatives were considered:

| Alternative | Effect | Verdict |
|---|---|---|
| **(a)** Remove the standby exception entirely (agents always poll) | Closes the gap; agents always self-correct | ❌ Rejected — the standby exception is a legitimate signal during human-driven workflows (e.g., "I'm reading the spec, don't act yet"). Removing it loses real value. |
| **(b)** Doctrine amendment only (no technical complement) | The agent that needs the wake is the agent that doesn't have the wake | ❌ Insufficient — the doctrine amendment is necessary but the agent in question can't self-detect the misapplied standby. The queue-empty wake breaks the loop. |
| **(c)** (chosen) Doctrine amendment + queue-empty wake | Bounded standby + automatic break-out on misapplication | ✅ Adopted — covers both the policy (doctrine) and the mechanism (technical). |

Alternative (c) is the **two-way-door-fast** (Bezos) heuristic applied to doctrine: the doctrine amendment is reversible (a one-line edit to `docs/CLAUDE.md`); the queue-empty wake is opt-in via env vars (default conservative). If the wake fires too aggressively, raising `QUEUE_EMPTY_THRESHOLD_POLLS` to 5 or 10 silences it without code changes.

### Why a synthetic wake (not a workflow / not a status field)

- **GitHub Action workflow** (label-check, status-label-to-board): possible but adds CI surface; the wake needs to fire on GitHub state, not on push events. Workflows are heavier and harder to test locally.
- **Projects v2 status field** (board lane): the queue is conceptual, not a board lane. Board hygiene is a separate concern.
- **Synthetic event in `agent-watch.sh`** (chosen): matches the existing event taxonomy (see `Event Model v6` in `scripts/agent-watch.sh` line 18, ADR-0024 §Event kind rename). No new infrastructure; the existing polling loop emits the event when the conditions match.

## Consequences

### Positive

- **Standby misapplication is structurally prevented**: the queue-empty wake is the watchdog for the doctrine amendment. Even if the human forgets to re-confirm, the agent wakes on priority-pending detection.
- **Doctrine is auditable**: the bounded standby text is a single sub-bullet in `docs/CLAUDE.md`, easy to review in retros, easy to amend.
- **No new infrastructure**: doctrine amendment is a doc edit; queue-empty wake is a function in `scripts/agent-watch.sh`. No new labels, no new workflows, no new auth surface.
- **Template-portable**: language is generic; the queue-empty query uses standard `gh` CLI filters. The dev-studio template can lift both without modification.

### Negative

- **Doctrine amendment requires human mirror**: `docs/CLAUDE.md` is human-owned (per file ownership matrix). The architect cannot directly edit it; the human must mirror the text after ADR acceptance. The ADR is the canonical record; the local `docs/CLAUDE.md` is the runtime binding.
- **Queue-empty wake may false-positive**: if the agent's priority items are intentionally parked (e.g., "human will handle merge"), the wake fires unnecessarily. Mitigation: the event payload names the priority items so the agent can self-verify; conservative default (P0 only).
- **Three-poll threshold (3 minutes) is heuristic**: too aggressive → noise; too lazy → stall window. Initial value (3) is conservative; can be tuned via `QUEUE_EMPTY_THRESHOLD_POLLS` env var.
- **Detection-after-fact**: the wake fires after the agent has already been in standby for 3+ minutes. Acceptable: priority work that's been waiting >3 minutes is already delayed; the wake breaks the loop and re-engages processing.

### Out of scope (this ADR)

- **Replacing the `standby` chat instruction with a structured directive** (e.g., a `directives.md` file in the project). Considered; deferred. The chat-thread re-confirmation is a low-friction convention; structured directives add process overhead.
- **Cross-agent standby coordination** (when one agent is in standby, do dependent agents also pause?). Considered; rejected. Each agent's queue is independent; cross-coordination is anti-pattern (couples agent autonomy).
- **CI gate enforcing the doctrine** (e.g., blocking PRs that say "standby forever"). Not possible: doctrine is about agent behavior, not PR content.
- **Issue #46 scope expansion** to include the queue-empty wake: deferred to owner decision. The wake could ship as part of Issue #46 (the umbrella P0 chore) or as a separate P1 follow-up.

### Follow-up tickets (to file when this ADR is accepted)

1. `@atilcan65` (human): mirror the bound-standby-exception text into `docs/CLAUDE.md` §Things agents must NEVER do. The text is in §Decision §1 above, verbatim. This is the canonical binding; the ADR is the rationale.
2. `@developer` (or `@orchestrator` — owner to assign): implement `query_queue_empty` in `scripts/agent-watch.sh` per §Decision §2. Add 3 regression tests: (1) priority P0 issue + 3 empty polls → wake fires; (2) no priority items + 3 empty polls → no wake; (3) priority P0 issue + 1 empty poll (below threshold) → no wake.
3. `@tester`: author d013 queue-empty-wake regression test (parse the watchdog's JSON output for the 3 scenarios).
4. `@architect`: file TD-013 (status flip responsibility matrix — see ADR-0021 §Status flip responsibility amendment) as a separate work item. Sister to this ADR.
5. `@atilcan65` (owner): decide whether the queue-empty wake ships as part of Issue #46 scope expansion or as a separate P1 follow-up.
6. **Issue #109 closure**: when this ADR is Accepted + `docs/CLAUDE.md` is mirrored + queue-empty wake is implemented + 1 sprint of validation passes, Issue #109's ACs are satisfied.

## Future work

- **Per-priority-list filtering**: extend the queue-empty wake to support per-agent priority lists (e.g., orchestrator cares about `priority:P0` + `needs-orchestrator`; developer cares about `priority:P0` + `agent:developer` + `status:ready`). The generic role+priority filter is a sensible default; per-agent customization is a future refinement.
- **Auto-deferral list**: agents that intentionally want to be in standby for N hours can set `AGENT_DEFER_UNTIL=<ISO-timestamp>` env var; the queue-empty wake respects the deferral window. Useful for "I'm at a conference, don't wake me until 14:00."
- **Doctrine linter**: a static check that flags `docs/CLAUDE.md` for missing bound-standby-exception sub-bullet (i.e., detects if the doctrine has drifted). Out of scope for this ADR.

---

**Sister ADRs:**
- **ADR-0020** (label-mutation transactionality) — closes the structural TD-004/TD-006/TD-008 class via wrapper tooling.
- **ADR-0021** (docs PR convention) — closes the docs-PR subclass of TD-006 via convention discipline. **This ADR amends ADR-0021** with a §Status flip responsibility section.
- **ADR-0024** (stale-verdict watchdog schema) — closes the watchdog target class of TD-006 via schema redesign.
- **ADR-0025** (this ADR) — closes the standby-extension class of TD-006 via doctrine + technical wake. Completes the TD-006 family of fixes.
