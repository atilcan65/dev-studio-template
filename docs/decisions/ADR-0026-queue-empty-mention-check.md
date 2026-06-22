# ADR-0026 — Queue-Empty Wake: @mention Check (Amendment to ADR-0025 §2)

**Status:** Proposed
**Date:** 2026-06-19
**Supersedes:** —
**Amends:** [ADR-0025](./ADR-0025-bound-standby-exception.md) §2 (Queue-Empty Wake — adds the @mention branch to the wake condition set)
**Related:** ADR-0002 (autonomy loop), ADR-0012 (4-cat invariant), ADR-0015 (atomic handoff), ADR-0021 (docs PR convention), ADR-0025 (bound standby + queue-empty wake), `docs/CLAUDE.md` §Autonomy Loop, Issue #109, Issue #113, cmt #4749006175 (trigger)

---

## Context

ADR-0025 §2 (queue-empty wake) was authored 2026-06-19 and merged via PR #110 at 2026-06-19T06:39:11Z. The §2 trigger condition is:

> The agent has at least one OPEN issue with `agent:<role>` AND (`priority:P0` OR `priority:P1`), OR an OPEN PR with `agent:<role>` AND `status:in-review` AND `needs-<role>-<action>` label.

This trigger set is **strictly label-ownership-based**. It does NOT catch `@<role>` mentions in issue/PR comments. The author (architect) discovered this gap on the same day ADR-0025 was filed: a 13-min-old `@architect` mention in [Issue #73 cmt #4748644731](https://github.com/atilcan65/AtilCalculator/issues/73#issuecomment-4748644731) (from @developer, 2026-06-19T05:02:59Z) was missed by the architect agent until the human chat-level wake-up at 2026-06-19T05:16Z (per the architect's own cmt #4749006175 "Doctrinal note"). The label-based filter excluded it because Issue #73 was `agent:developer | cc:architect` (cc, not agent) — but the comment text `@architect` was the actionable signal, and the queue filter didn't see it.

The gap is real and is the **same class of bug** that ADR-0025 §1 (bound standby exception) was authored to prevent. The label filter is necessary but not sufficient. The doctrinally-aligned fix is: **add a `query_assigned_mentions` branch to the queue-empty wake trigger set** that scans `@<role>` mentions in comments on issues/PRs that the agent is `cc:*` on, or that are not yet assigned.

This ADR is the **deliverable** the architect committed to in cmt #4749006175 ("Will amend PR #110 in next push") — filed as a separate ADR per the doctrine that "Accepted ADRs are immutable; supersede/amend via a new ADR" (per `docs/decisions/INDEX.md` conventions).

## Decision

**Amend ADR-0025 §2 (Queue-Empty Wake trigger condition) to add the `@mention` branch.**

### Updated §2 trigger condition (replaces the condition in ADR-0025 §2)

The queue-empty wake event fires when ALL of the following hold for N consecutive polls (default N=3, ~3 minutes):

- `new_events: []` for the past N polls, AND
- ANY of the following priority conditions:
  - **(a)** The agent has at least one OPEN issue with `agent:<role>` AND (`priority:P0` OR `priority:P1`), OR
  - **(b)** The agent has at least one OPEN PR with `agent:<role>` AND `status:in-review` AND `needs-<role>-<action>` label, OR
  - **(c) — NEW**: The agent has at least one OPEN issue or PR where `@<role>` appears in a comment in the last K minutes (default K=60) AND the agent is NOT already in `cc:<role>` on that issue/PR.

The `(c)` branch addresses the @mention gap. The `NOT already in cc:<role>` guard prevents double-wake: if the architect is `cc:architect` on Issue #73, the architect already gets the normal `pr_comment_mention` wake on every new comment — the queue-empty check would be a redundant second signal.

### Event payload (additions to ADR-0025 §2 payload)

The `priority_items` array adds the new shape:

```json
{
  "type": "mention",
  "number": 73,
  "title": "STORY-011: Scientific functions ...",
  "url": "https://github.com/<org>/<repo>/issues/73#issuecomment-4748644731",
  "comment_author": "developer",
  "comment_age_min": 13,
  "comment_excerpt": "@architect — karar verdiğinde Issue #73'e ...",
  "is_cc_role_already": true,
  "note": "@<role> mention in comment; the role is also cc:role (already in queue via normal wake), so this is informational only."
}
```

If `is_cc_role_already: false` (the actionable case), the `note` field becomes:

> `@<role> mention in comment, role NOT yet cc:role. Possible wake miss (label-based queue filter excluded this). Read the comment, decide if action is needed, post a response and/or flip cc:<role> on the issue/PR per ADR-0015 atomic handoff.

### Implementation: `query_assigned_mentions` POC

In `scripts/agent-watch.sh`, add the following function (POC, ~25 lines):

```bash
query_assigned_mentions() {
  local role="$1"
  local since_iso="$2"  # e.g., "60 minutes ago"
  # gh search scopes @<role> mentions to comments on issues+PRs the role is NOT already cc:on
  gh search issues "@${role} in:comments created:>${since_iso}" \
    --state open --limit 20 --json number,title,updatedAt,url \
    | jq -c --arg role "$role" '
        .[] |
        select(. as $item |
          # exclude items already cc:role (handled by normal wake)
          (gh pr view $item.number --json labels 2>/dev/null |
            [.labels[].name | select(. == "cc:" + $role)] | length == 0)
        ) |
        {type:"mention", number: .number, title: .title, url: .url,
         updatedAt: .updatedAt}
      '
}
```

This is a POC — the actual implementation is owned by @developer and lives in the @developer worktree. The function is template-portable: it uses standard `gh search` and `gh pr view` filters.

### Configuration (env vars on `agent-watch.sh`)

- `QUEUE_EMPTY_MENTION_LOOKBACK_MIN` (default 60) — how far back to scan for @mentions
- `QUEUE_EMPTY_MENTION_LIMIT` (default 20) — max items per scan

### Throttle scheme

The new `mention` event kind is **bucketed at 5-minute resolution** (same as `stale_cc` and `stale_verdict`). Event ID: `mention-<role>-<issue-or-pr-number>-<5min-bucket>`. This prevents the wake from re-firing every poll on the same comment.

## Rationale

The label-only filter for queue-empty wake is **structurally insufficient**. Labels are ownership signals; @mentions are **actionable signals**, often from a peer asking for input. The two signal classes complement each other:

- **Labels**: "this is mine to do" (ownership)
- **@mentions**: "I need your input" (actionable request)

The queue-empty wake should cover both, otherwise the agent can be in standby while a peer is waiting for a verdict (the exact pattern observed on Issue #73 cmt #4748644731).

Three alternatives were considered:

| Alternative | Effect | Verdict |
|---|---|---|
| **(a)** Trust labels only; add a "check comments manually" guidance to the soul doc | Closes the doctrine gap; no code change | ❌ Rejected — "check comments manually" is the same anti-pattern as "agent should just remember." The wake is the mechanism, not the soul guidance. |
| **(b)** Use `gh notifications` API to surface all @mentions in the agent's view | Comprehensive; agent sees everything | ❌ Rejected — too noisy; would re-introduce the TD-006 spam pattern (every mention fires, regardless of actionability). |
| **(c)** (chosen) Add @mention check to queue-empty wake with cc:<role> dedup | Targeted; non-redundant; bounded | ✅ Adopted — matches ADR-0025 §2's anti-stall intent. |

Alternative (c) follows the **boring tech wins** heuristic: one new query, one new event kind, one new env var. No new tooling. Reuses `gh search` (already used in `agent-watch.sh`).

## Consequences

### Positive

- **The 13-min Issue #73 miss pattern is structurally prevented**: the architect would have woken on the @mention branch of the queue-empty check within 3 minutes (the N=3 poll threshold) of the @architect comment, even with `agent:developer` ownership.
- **Cross-cutting gap closure**: the same fix applies to all 5 agent roles (each one's queue-empty check now includes @self mentions).
- **Doctrine consistency**: ADR-0025 §1 (bound standby) and §2 (queue-empty wake) are now both **mention-aware** — agents in bounded standby who receive @mentions are detected.
- **CC dedup preserves the existing wake taxonomy**: agents already in `cc:<role>` continue to get the normal `pr_comment_mention` wake; the queue-empty check is a fallback, not a duplicate.

### Negative

- **`gh search` API cost**: the new query adds 1 API call per poll cycle per agent (per role). 5 agents × 1 call/poll = 5 calls/poll. At 60s polling, that's 300 calls/hour. Within the standard 5000/hour rate limit, but a budget consideration. Mitigation: `QUEUE_EMPTY_MENTION_LIMIT=20` caps per-call result size.
- **False positives**: an `@architect` mention in a casual comment (e.g., "thanks @architect for the design") will trigger the wake. The agent self-verifies per ADR-0025 §2 ("if priority work is NOT found, takes no action"), so the cost is one extra poll cycle, not a real action. Acceptable.
- **Search scope is "comments only"**: issue/PR body text and titles are not scanned. If a peer's @mention is in the body (e.g., a checklist "ping @architect for review"), it's missed. Out of scope for this ADR — defer to a follow-up if the pattern emerges.

### Out of scope (this ADR)

- **Mentioning multiple roles in one wake** (e.g., `@architect @tester` in the same comment). Each agent's queue-empty check fires independently. Acceptable.
- **Tracking mention-acknowledgement** (the wake fires once, even if the agent hasn't responded yet). The 5-minute bucket throttle handles this; if the agent doesn't respond within 5 min, the wake re-fires. Same throttle scheme as `stale_cc` and `stale_verdict`.
- **Bidirectional @mention** (agent auto-pings the peer back). Out of scope — that's the Auto-Ping Hard-Rule, separate from the queue-empty wake.

### Follow-up tickets (to file when this ADR is accepted)

1. `@developer`: implement `query_assigned_mentions` in `scripts/agent-watch.sh` per §Implementation. Add 3 regression tests: (1) @<role> comment + 3 empty polls + role not cc → wake fires; (2) @<role> comment + role IS cc → no wake (dedup); (3) no @<role> comment + 3 empty polls + no priority items → no wake.
2. `@tester`: author d014 mention-check regression test (parse the watchdog's JSON output for the 3 scenarios above).
3. `@architect`: update the 5 soul docs to reference this ADR (the wake now catches @mentions; soul should mention the new event kind in the §Autonomy Loop section).
4. `@atilcan65`: approve the doctrine change. Acceptance closes the cmt #4749006175 deliverable.

## Future work

- **Body-text @mention scan**: extend the query to include issue/PR body text. Useful for "ping @architect for review" checklist items. Defer until the gap is observed in production.
- **Cross-agent mention summary**: a daily digest of @mentions across all agents, for the orchestrator's sprint standup. Out of scope.
- **Mention-ack SLA tracking**: track time from @mention to agent response, surface SLA violations. Same shape as ADR-0024 §SLA; defer to a follow-up.

---

**Sister ADRs:**
- **ADR-0025** (this ADR amends its §2) — bound standby + queue-empty wake (original). The mention-check is the missing third branch of the trigger condition set.
- **ADR-0024** — stale-verdict watchdog schema. The mention-check shares the 5-minute bucket throttle scheme with `stale_verdict`.

**Trigger**: architect cmt #4749006175 (2026-06-19T06:18:46Z, Issue #73) — "queue-empty wake must also check for peer `@<role>` mentions even when the issue/PR is not architect-owned."
