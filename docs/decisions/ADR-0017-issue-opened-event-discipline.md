# ADR-0017 — Issue-opened event discipline

**Status:** Accepted
**Date:** 2026-06-15
**Supersedes:** none
**Refs:** ADR-0005 (PR-merged events), ADR-0008 (label-conditional fanout), ADR-0010 (per-project watchers), ADR-0015 (atomic handoff), ADR-0016 (issues-only board)

## Context

The agent-watch.sh poll loop emits events from eight queries, deduped via `processed_event_ids` in each role's state file. Each query has a high-water mark (HWM) timestamp guarding it:

| Query | HWM field | Filter |
|---|---|---|
| `query_assigned_issues` | `last_seen_utc` (shared) | `updatedAt > LAST_SEEN` |
| `query_review_requests` | `last_seen_utc` (shared) | — (relies on dedup) |
| `query_new_commits_on_assigned_prs` | `last_seen_utc` (shared) | — |
| `query_pr_mentions` | `last_seen_utc` (shared) | — |
| `query_stale_cc` | `last_seen_utc` (shared) | — |
| `query_board_changes` | `last_seen_utc` (shared) | `updatedAt > LAST_SEEN` |
| `query_pr_merged` | `pr_merged_last_seen_utc` (dedicated) | `mergedAt > HWM` |
| `query_pr_labeled` | `pr_labeled_last_seen_utc` (dedicated) | `updatedAt > HWM` |

`last_seen_utc` is bumped on **every poll** (`poll_once` tail). Six of the eight queries above share it.

## Problem

A newly-created issue carrying `agent:<role>` is intended to wake exactly one watcher (its assignee role) via `query_assigned_issues`. The query filter is `updatedAt > LAST_SEEN`.

The shared-HWM design has a silent-drop race:

1. Poll cycle starts. `LAST_SEEN` is read as `T0`.
2. Mid-cycle, a sibling query (e.g. `query_pr_merged`) materializes an event. Its post-processing path calls `$STATE_HELPER set ... last_seen_utc $now` indirectly via `mark` (which bumps `last_seen_utc` per `cmd_mark` in agent-state.sh).
3. Poll cycle ends. `last_seen_utc` is now `now > T0`.
4. **Between step 1 and step 3, a new issue is created with `createdAt = T1` where `T0 < T1 < now`.**
5. Next poll. `LAST_SEEN` is read as `now`. The new issue has `updatedAt = T1 < now`. The `updatedAt > LAST_SEEN` filter drops it silently.
6. The issue never updates again (no comments, no relabel) → its `updatedAt` stays at `T1` forever → the filter eats it forever.

This was observed on AtilCalculator Round 6 Sprint-1 kickoff (Issue #3):
- Issue createdAt: `2026-06-15T20:16:18Z`
- Orchestrator `last_seen_utc` at observation time: `2026-06-15T20:39:53Z`
- `processed_event_ids` did not contain `issue-assigned-3-*` — proof the query never returned it.
- gh query verified by hand: same `--label "agent:orchestrator" --state open` returned Issue #3. The miss was the JQ filter, not the underlying API.

## Decision

Introduce a ninth query, `query_issue_opened`, with these properties:

1. **Dedicated HWM** `issue_opened_last_seen_utc` — independent from `last_seen_utc`.
2. **`createdAt`-based filter** `createdAt > ISSUE_OPENED_LAST_SEEN` — `createdAt` is immutable per GitHub semantics, so the filter target never moves out from under us.
3. **Event ID** `issue-opened-<n>-<createdAt>` — unique per issue (createdAt is write-once), so `processed_event_ids` dedup prevents re-fire across polls.
4. **HWM advances every poll** to `now` — caps backfill on subsequent polls, identical pattern to `last_seen_utc`.
5. **First-poll backfill** of 5 minutes (`ISSUE_OPENED_BACKFILL` env, default `"5 minutes ago"`) — covers the gap between `new-project.sh` returning and the first watcher poll firing on a fresh repo.

Old `query_assigned_issues` is **kept unchanged**. It continues to fire on label changes / comments / reassignments (any `updatedAt` bump) as before.

## Consequences

### Positive

- New issues with `agent:<role>` reliably wake their watcher within one poll interval (≤60s).
- Backward compatible: existing event types unaffected. Existing state files backfill `issue_opened_last_seen_utc = null` on next `agent-state.sh init`.
- Independent HWM eliminates the cross-event race class. Any future query added with its own HWM gets the same robustness.

### Negative / accepted

- One extra `gh issue list` call per poll per watcher (= 5 watchers × 1/min = 5 extra API calls/min/project). Within GitHub REST rate budget (5000/h) by 2 orders of magnitude.
- Issue can fire **both** `issue_opened` (createdAt event) and `issue_assigned` (updatedAt event) on first poll — dedup via `processed_event_ids` ensures the agent only wakes once. Both have distinct event IDs so neither shadows the other.

### Non-goals

- Does not change board sync, label invariant, or PR-merged fanout. Those remain ADR-0013/0012/0008/0016.
- Does not introduce per-event-type processed lists. Single `processed_event_ids` is sufficient because event IDs are namespaced by prefix.

## Verification

After this PR merges, on the next `new-project.sh <NAME>` cycle:

1. Open a fresh issue with `agent:orchestrator`.
2. Within ≤2 poll intervals (≤120s), verify the orchestrator state file contains an `issue-opened-<n>-<createdAt>` entry in `processed_event_ids`.
3. Verify the tmux orchestrator pane received a wake.

Failure path: if `query_issue_opened` returns `[]` despite the issue being present in `gh issue list --label "agent:orchestrator"`, the JQ filter is the culprit — check `ISSUE_OPENED_LAST_SEEN` is older than the issue's `createdAt`.

## Reversal

Set `ISSUE_OPENED_BACKFILL=""` to disable backfill (HWM defaults to `now` on first poll, so no historical issues are emitted). To fully revert: remove `query_issue_opened` call and merge line from `poll_once`. State field can stay (harmless).
