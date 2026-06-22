# ADR-0024 — Stale-Verdict Watchdog Schema (`verdict-by:<ts>` labels + `stale_verdict` events)

**Status:** Proposed
**Date:** 2026-06-19
**Supersedes:** —
**Related:** ADR-0002 (autonomy loop), ADR-0009 (label discipline), ADR-0012 (4-cat invariant), ADR-0015 (atomic handoff), ADR-0020 (label-mutation transactionality), ADR-0021 (docs PR convention), TD-006 (umbrella), Issue #46 (P0 chore), `scripts/agent-watch.sh` line 770 (`query_stale_cc`)

---

## Context

The autonomy loop's watchdog (`scripts/agent-watch.sh: query_stale_cc`, lines 770–805) currently fires `stale_cc` events whenever a `cc:<role>` label sits on an open PR for > 900 s (15 min) without any state change. The intent is a deadlock-breaker (ADR-0002 §Event Model v2): if a wake was lost (watcher restart, tmux race, processed_event_ids corruption), the stall self-heals.

The **observed failure pattern** (TD-006 + Issue #46 + 4 prior incidents this session): docs PRs and PRs with "for-awareness" `cc:*` labels trigger the watchdog on every poll cycle (5-min bucket), producing **queue noise without any actual review happening**. Test PRs without a real review expectation are the worst offenders — the watchdog fires every 15 min for the lifetime of the PR.

| ID | Symptom | Mechanism | Frequency observed |
|---|---|---|---|
| **TD-005** | Architect's `cc:architect` reverts silently | Orchestrator's hygiene script over-removes | 1× / sprint |
| **TD-006** | Same — orchestrator's `gh pr edit --remove-label cc:orchestrator` hits architect's `cc:architect` in the same transaction | Non-selective bulk hygiene | 1× / sprint |
| **TD-008** | `gh pr edit` removes MORE labels than requested | `gh pr edit` semantics ambiguous | 1× / sprint |
| **Issue #46 (P0)** | `stale_cc` events fire on docs PRs every 15 min for PR lifetime | Watchdog target = label presence, not "review verdict expectation" | **continuous** — every PR with `cc:*` that has no reviewer action |

ADR-0020 (label-mutation transactionality wrapper + CI gate) addresses TD-004 / TD-006 / TD-008 **structurally** — the wrapper enforces atomicity, isolation, verification, rollback around every label flip. ADR-0021 (docs PR convention) addresses the docs-PR **subclass** — `type:docs` PRs default to `agent:<author>` only, no peer `cc:*` without an explicit `## Peer review rationale` section. Both ADRs are **Accepted** (merged 2026-06-18).

What's **not yet designed**: a **watchdog schema** that distinguishes "reviewer is expected to act" from "label is present." The current `stale_cc` event conflates these. Issue #46's **structural ACs #2 + #3** ask for:

> **#2** Watchdog rewrites expectation: changes target ("review verdict") not label presence
> **#3** Stale_cc watchdog schema: `stale_verdict:<pr#>` not `stale_cc:<pr#>`

This ADR proposes the schema change that satisfies those ACs.

## Decision

**The watchdog's stall target shifts from "label presence" to "review verdict expectation."** Every peer `cc:<role>` MUST be paired (or implicitly paired) with a `verdict-by:<iso-timestamp>` label that names the verdict-deadline. The watchdog emits `stale_verdict:<pr#>` events **only** when a `verdict-by:<ts>` deadline has passed without a state change — not when a `cc:<role>` label has been unchanged for N minutes.

### Schema additions

| New label | Format | Meaning | Set by | Removed by |
|---|---|---|---|---|
| `verdict-by:<iso-timestamp>` | e.g., `verdict-by:2026-06-19T18:00:00Z` | Deadline by which the peer reviewer is expected to post a verdict (APPROVED / NEEDS CHANGES / etc.) | The agent who adds `cc:<peer>` (the "asker") | The peer reviewer on posting verdict (atomic `cc:<peer>` flip removes the deadline), OR the human on merge |

**Convention**: when an agent adds `cc:<peer>` to a PR, they MUST also add `verdict-by:<ts>` in the same atomic flip (per ADR-0015 §Sıra zorunlu). The deadline MUST be expressed in the PR body's `## Peer review rationale` section (per ADR-0021 §PR body convention); the label is the machine-readable mirror.

### Watchdog logic (post-ADR-0024)

The current `query_stale_cc` (lines 770–805) is replaced by `query_stale_verdict`:

```bash
query_stale_verdict() {
  # Stall target = verdict-by:<ts> deadline passed without state change.
  # cc:<role> alone is no longer sufficient; the expectation is what matters.
  local now_epoch bucket
  now_epoch="$(date -u +%s)"
  bucket=$(( now_epoch / 300 ))

  gh pr list \
    --repo "$REPO" \
    --state open \
    --limit 50 \
    --json number,title,url,updatedAt,headRefOid,labels \
    --jq "[ .[] |
           .labels as \$labels |
           (\$labels | map(.name) | map(select(startswith(\"verdict-by:\"))) | first) as \$deadline |
           select(\$deadline != null) |
           (\$deadline | sub(\"verdict-by:\"; \"\") | fromdateiso8601) as \$deadline_epoch |
           select(\$deadline_epoch < $now_epoch) |
           ((now - (.updatedAt | fromdateiso8601)) | floor) as \$age |
           select(\$age > ${STALE_VERDICT_GRACE_SEC:-300}) |
           {
             id: (\"stale-verdict-\" + (.number | tostring) + \"-\" + (.headRefOid[0:7]) + \"-b\${bucket}\"),
             kind: \"stale_verdict\",
             number: .number,
             title: .title,
             url: .url,
             updated_at: .updatedAt,
             context: {
               age_sec: \$age,
               head_sha: .headRefOid[0:7],
               deadline: \$deadline,
               note: \"verdict-by:<\$deadline> passed; cc:<role> peer expected to act.\"
             }
           } ]"
}
```

### Event kind rename: `stale_cc` → `stale_verdict`

The event `kind` field changes from `stale_cc` to `stale_verdict`. The event `id` format changes from `stale-cc-<n>-<sha7>-b<bucket>` to `stale-verdict-<n>-<sha7>-b<bucket>`. This is a **breaking change** for any agent or tooling that parses the event stream. A **back-compat shim** is required:

1. **One-sprint deprecation period (2026-06-19 → 2026-07-02)**: the watchdog emits both `stale_cc` (legacy) and `stale_verdict` (new) when the conditions match either path. Agents are expected to migrate to `stale_verdict` parsing.
2. **Post-deprecation (2026-07-02+)**: `stale_cc` events stop being emitted. Only `stale_verdict` fires. Agents still parsing `stale_cc` will see zero events (silent failure risk — see §Migration risks).

### Interaction with ADR-0021 §Watchdog amendment

ADR-0021 §Watchdog amendment adds a docs-PR suppression: `type:docs` PRs without `## Peer review rationale` section get **no `stale_*` wake**. That suppression applies to BOTH `stale_cc` (legacy) and `stale_verdict` (new). If a `type:docs` PR HAS the rationale section AND has a `verdict-by:<ts>` label, the new `stale_verdict` path applies. Otherwise, no wake — the suppression wins.

### Missing-expectation warning (separate event kind)

If a PR has `cc:<peer>` but NO `verdict-by:<ts>` label, the watchdog emits a `missing_expectation:<pr#>` warning (one-shot, not bucketed). This catches the convention violation without spamming on every poll cycle.

```bash
query_missing_expectation() {
  # Convention violation: cc:<peer> without verdict-by:<ts>.
  # One-shot per PR (id embeds pr# only, not bucket).
  gh pr list \
    --repo "$REPO" \
    --state open \
    --limit 50 \
    --json number,title,url,updatedAt,headRefOid,labels \
    --jq "[ .[] |
           .labels as \$labels |
           (\$labels | map(.name) | map(select(startswith(\"cc:\"))) | first) as \$cc |
           select(\$cc != null) |
           (\$labels | map(.name) | map(select(startswith(\"verdict-by:\"))) | first) as \$deadline |
           select(\$deadline == null) |
           {
             id: (\"missing-expectation-\" + (.number | tostring) + \"-\" + (.headRefOid[0:7])),
             kind: \"missing_expectation\",
             number: .number,
             title: .title,
             url: .url,
             updated_at: .updatedAt,
             context: {
               head_sha: .headRefOid[0:7],
               cc_present: \$cc,
               note: \"cc:<peer> without verdict-by:<ts>; convention violation per ADR-0024 §Schema additions.\"
             }
           } ]"
}
```

This warning fires **once** per (PR, head_sha) pair — the agent who sees it either adds the missing `verdict-by:<ts>` label (closes the gap) or removes the `cc:<peer>` label (legitimate cleanup). Both actions advance the head SHA, so the event id changes and the warning does not re-fire.

## Rationale

The current `stale_cc` design conflates two distinct concepts: **peer awareness** ("I should know about this PR") and **peer expectation** ("this peer should post a verdict by deadline X"). For docs PRs, only the first applies; for code PRs under active review, the second applies. Lumping them together produces the spam.

### Alternatives considered

| Alternative | Effect | Verdict |
|---|---|---|
| **(a)** Keep `stale_cc` as-is; tighten the time threshold (e.g., 900 s → 3600 s) | Fewer wakes, but the signal-to-noise ratio doesn't improve — long-stale reviews still go unflagged | ❌ Rejected — symptom treatment, not root cause |
| **(b)** Add a per-PR suppression list (`scripts/agent-watch.sh` config file) | Operator-managed allowlist of "this PR is fine, don't wake" | ❌ Rejected — config drift; doesn't scale; bypasses the convention |
| **(c)** (chosen) Replace `stale_cc` with `stale_verdict` + `verdict-by:<ts>` label; add `missing_expectation` for convention violations | The watchdog now distinguishes "reviewer expected to act" from "label present" | ✅ Adopted — root cause fix; convention + machine check, both |
| **(d)** Replace `cc:*` entirely with `verdict-by:<ts>` (single label per peer) | Eliminates the `cc:*` / `verdict-by` split | ❌ Rejected — bigger taxonomy change; ADR-0012 / ADR-0015 hand-off discipline is built around `cc:*`; risk vs. benefit doesn't justify |

Alternative (c) matches the **boring tech wins** heuristic: it adds one label format and rewrites one function (~30 lines net). No new dependencies. No new auth surface. The watchdog still uses `gh` + jq + bash — the same stack. The back-compat shim preserves agent parsing during the deprecation window.

### Why `verdict-by:<ts>` as a label (not a PR comment, not a project field)

- **PR comment**: stale, hard to parse, version-controlled but invisible to `gh pr list --json labels`. A query that doesn't see comments can't enforce the deadline.
- **Project field**: Projects v2 status fields are mutable from a UI; programmatic reads require `gh project` (separate API). Adds a dependency surface.
- **Label** (chosen): declarative, atomic, version-controlled, queryable via `gh pr list --json labels`. Easy to add (`gh pr edit --add-label`) and easy to remove (same). Pairs cleanly with `cc:<peer>` (the asker adds both in one atomic flip per ADR-0015).

## Consequences

### Positive

- **Structural fix for TD-006 subclass on docs PRs**: `type:docs` PRs without peer review rationale get NO wake (ADR-0021 suppression). `type:docs` PRs WITH rationale + `verdict-by:<ts>` only fire when the deadline passes — not every 15 min.
- **Signal clarity**: `stale_verdict` events carry semantic meaning ("verdict deadline passed") instead of just label-presence signal ("label sat for N minutes"). Agents can route to verdict-lift action or peer-poke based on the new event.
- **Convention enforcement**: `missing_expectation` warnings catch the "cc:<peer> without verdict-by:<ts>" convention violation one-shot, not as a stall. Agents fix it immediately or remove the cc:*.
- **Reduced queue noise**: target = 0 spurious `stale_*` wakes on docs PRs (per Issue #46 AC: "1 sprint without TD-006-class spam wakes"). Validation: `agent-watch orchestrator | jq '.new_events | map(select(.kind == "stale_verdict" or .kind == "stale_cc")) | length' == 0` for non-blocker PRs.
- **Backwards-compatible migration**: one-sprint shim ensures existing agents keep working. After 2026-07-02, agents not migrated will see zero wakes — a loud silent failure that the watchdog's existing heartbeat / staleness alarm will catch (per agent-doctor.sh).

### Negative

- **Schema migration cost**: every agent's `agent-watch.sh` consumer code must learn to parse `stale_verdict` (kind + id format). Estimated ~5 lines of change per agent (3 active roles: architect, developer, tester; orchestrator already sweeps all kinds).
- **Convention enforcement surface**: the convention "every cc:<peer> MUST have a verdict-by:<ts>" is new. Until muscle memory builds, agents may forget — the `missing_expectation` warning catches this, but it relies on the watchdog emitting the warning AND the relevant agent acting on it.
- **Back-compat shim complexity**: the watchdog emits two event kinds during the deprecation window. This is temporary (1 sprint) but increases the test surface.
- **Backwards silent failure risk**: post-2026-07-02, agents still parsing `stale_cc` see zero events. Mitigation: the agent-watch heartbeat (`last_heartbeat_utc` + agent-doctor.sh cron) detects role stall within 30 min, raising a Telegram warn. But it's a longer detection lag than the old wake.

### Out of scope (this ADR)

- **Replacement of `cc:*` entirely** (alternative (d) above). Considered; rejected. ADR-0012 / ADR-0015 hand-off discipline is built around `cc:*`; replacing it is a bigger change with no clear benefit.
- **A new "verdict" event kind** for the actual verdict lift (e.g., `verdict_lifted:<pr#>` when a reviewer posts APPROVED). Considered; deferred. The current verdict is captured in PR comment threads + `reviewDecision` field; a dedicated event kind is structural-overkill for the MVP.
- **CI gate enforcing the convention** (e.g., `gh label-check` workflow rejects `cc:<peer>` without `verdict-by:<ts>`). Considered; deferred to ADR-0025 if the `missing_expectation` warning alone is insufficient.

### Follow-up tickets (to file when this ADR is accepted)

1. `@developer`: implement `query_stale_verdict` + `query_missing_expectation` in `scripts/agent-watch.sh` per §Watchdog logic + §Missing-expectation warning. Add the one-sprint back-compat shim (`stale_cc` continues to emit alongside `stale_verdict` until 2026-07-02). Add 3 regression tests: (1) PR with `verdict-by:<ts>` in the past → `stale_verdict` fires; (2) PR with `verdict-by:<ts>` in the future → no wake; (3) PR with `cc:<peer>` but no `verdict-by:<ts>` → `missing_expectation` fires one-shot.
2. `@developer` (or `@architect`): update each of the 5 soul docs (orchestrator / architect / developer / tester / PM) to reference the new convention + event kinds.
3. `@tester`: author d012-stale-verdict-schema regression test (parse the watchdog's JSON output for the 3 scenarios).
4. `@orchestrator`: amend `scripts/agent-watch.sh` watchdog's `proactive_scan` event model (Event Model v5, Issue #44) to include `stale_verdict` and `missing_expectation` in the periodic synthetic-wake set.
5. `@architect`: update `docs/tech-debt.md` TD-006 entry to mark resolution via ADR-0024 (schema change) + ADR-0020 (wrapper) + ADR-0021 (docs subclass).
6. **Issue #46 closure**: when this ADR is Accepted + the watchdog is updated, Issue #46 ACs #2, #3 (short-term) are structurally enforced by the watchdog; AC #1 (validation: 1 sprint without spam) runs from 2026-06-19 → 2026-07-02 in parallel with the back-compat shim.

## Future work

- **Auto-verdict-by**: a PR-template hook that auto-fills `verdict-by:<default-deadline>` (e.g., 24h from PR creation) on `cc:<peer>` addition. Reduces convention friction. Out of scope for this ADR.
- **Verdict-lift event kind** (see §Out of scope). Defer until the convention is stable.
- **CI gate enforcing the convention** (see §Out of scope). Defer to ADR-0025 if `missing_expectation` alone is insufficient.

---

**Sister ADRs:**
- **ADR-0020** (label-mutation transactionality) — closes the structural TD-004/TD-006/TD-008 class via wrapper tooling.
- **ADR-0021** (docs PR convention) — closes the docs-PR subclass of TD-006 via convention discipline.
- **ADR-0024** (this ADR) — closes the watchdog target class of TD-006 via schema redesign (`verdict-by:<ts>` + `stale_verdict` event).
