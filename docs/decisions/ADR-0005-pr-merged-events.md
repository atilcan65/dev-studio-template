# ADR-0005: Post-Merge Lifecycle Events (`pr_merged`)

- Status: Accepted
- Date: 2026-06-11
- Deciders: orchestrator + human operator
- Supersedes: extends ADR-0003 (Event Model v2)
- Refs: ADR-0002 (GitHub-Native Autonomy), ADR-0003 (Event Model v2), ADR-0004 (Bootstrap Auto-Kickoff)

## Context

The Multi-Agent Dev Studio template uses GitHub as its single source of truth for agent
work queues. ADR-0003 codified five event kinds for the **inbound** lifecycle (work
arriving at an agent): `issue_assigned`, `pr_review_requested`, `pr_new_commit`,
`pr_comment_mention`, `stale_cc`, `label_change`.

After PR #34 merged on 2026-06-10 we observed a gap: **no agent woke up.** The PR was
authored by `developer`, reviewed by `tester`, and merged by the human operator, but
none of the downstream cleanup actions ran — no branch prune, no sprint-board update,
no orchestrator re-dispatch. Each role's local view of the world drifted out of sync
with `main`.

The root cause is structural, not a bug: the v2 taxonomy has no **outbound** lifecycle
event. Merge is the moment when "work in flight" becomes "work done", and several roles
have well-defined work to do at that boundary. Without a `pr_merged` event the watcher
loop ignores merges entirely.

This ADR adds `pr_merged` as the sixth event kind and defines its fan-out semantics.

## Decision

### 1. Event kind: `pr_merged`

Watcher (`agent-watch.sh`) polls `gh pr list --state merged --search "merged:>$HWM"`
on every loop iteration. Each new merge emits one event per fan-out role.

**Event ID:** `pr-merged-<pr_number>-<sha7>` where `sha7` is the first 7 characters
of the merge-commit OID. This makes the ID unique per merge (force-push to `main` is
extremely rare on a protected branch but, if it ever happens, re-fires the event with
a new SHA — correct behaviour).

**Payload:**

```json
{
  "id": "pr-merged-34-7664a72",
  "kind": "pr_merged",
  "number": 34,
  "title": "fix(pr-d-d1): correct heredoc expansion ...",
  "url": "https://github.com/atilcan65/atilprojects/pull/34",
  "updated_at": "2026-06-10T20:16:51Z",
  "context": {
    "merge_sha": "7664a72",
    "merged_at": "2026-06-10T20:16:51Z",
    "author": "atilcan65",
    "labels": ["fix", "pr-d"]
  }
}
```

### 2. Fan-out (MVP)

Three roles always receive `pr_merged`:

| Role              | Post-merge action                                                |
|-------------------|------------------------------------------------------------------|
| `orchestrator`    | Refresh sprint state, re-dispatch next story if developer is idle |
| `product-manager` | Move story to Done column, update velocity / burn-down            |
| `developer`       | Prune local branch, clean working tree, mark story complete       |

`architect` and `tester` are deliberately **excluded** from MVP fan-out. Most merges
don't change the architecture or warrant a regression sweep. Label-conditional fan-out
(`needs-design`, `needs-test`, or path-based triggers) is deferred to a follow-up ADR.

Fan-out roles are encoded in `agent-watch.sh` as a single shell variable:

```bash
PR_MERGED_FANOUT_ROLES="orchestrator product-manager developer"
```

Each role's `agent-watch.sh` instance independently decides whether to query merged
PRs based on this list, so adding a role is a one-line change.

### 3. Dedup & high-water mark (B2 from the design memo)

A new state-file field is introduced:

```json
{
  "role": "developer",
  "last_seen_utc": "...",
  "processed_event_ids": [...],
  "pr_merged_last_seen_utc": "2026-06-10T20:16:51Z",
  "poll_interval_sec": 60,
  "last_heartbeat_utc": "..."
}
```

`pr_merged_last_seen_utc` is **decoupled** from `last_seen_utc`. `last_seen_utc` is
event-mark-driven (bumps when any event is processed); reusing it for merge polling
creates a race when poll interval and merge interval overlap. A separate high-water
mark is also self-documenting and follows the pattern we'd reuse for any future
"poll a remote feed since timestamp X" event source.

**Initialization:** on first read, if the field is missing or `null`, it is back-filled
to `now() - PR_MERGED_BACKFILL` so a fresh state file doesn't replay every historical
merge. `PR_MERGED_BACKFILL` is an env-overridable GNU-date expression; default `1 hour
ago` (see "Backfill window sizing" below for rationale).

**Three layers of dedup defense:**

1. `pr_merged_last_seen_utc` filters the `gh pr list` query at source.
2. `processed_event_ids` ring buffer (FIFO, default size 50) drops anything already
   processed — covers watcher restarts and clock skew.
3. Event ID embeds merge SHA, so identity is content-addressed: even if a PR is
   re-merged (force-push to `main` with a new commit), the new SHA = new event.

### 4. No bot-loop filter (C3 from the design memo)

In the current single-user setup the merge actor is always the human operator,
so an agent cannot trigger its own `pr_merged` event. Layer 2 (dedup ring buffer)
provides sufficient protection against accidental re-emission. If we later give
each agent its own GitHub bot identity, a `merged_by != self` filter can be added
with a four-line patch — but it is **not** added now to keep the MVP minimal.

## Consequences

### Positive

- **Closes the post-merge silence.** Sprint board updates, branch pruning, and
  re-dispatch are no longer manual chores.
- **Template-grade.** The high-water-mark pattern, fan-out list, and ID format
  generalise to any future "watch a remote stream of completion events" need
  (issue closed, deployment success, security alert resolved, etc.).
- **Backward compatible.** Existing watchers and state files keep working; the new
  field is read with a default and written lazily.

### Negative

- One extra `gh pr list` call per poll per role in `PR_MERGED_FANOUT_ROLES`. With
  three roles at 60-second cadence that's ~4 320 extra API calls per day, well
  under GitHub's 5 000/hour authenticated quota.
- Architect and tester silently miss merges that affect them. Mitigated by the
  follow-up label-conditional fan-out work; in the meantime the human can hand
  them a `pr-mention` via PR comment.

### Risks accepted

- A PR merged within the first poll after `pr_merged_last_seen_utc` is backfilled
  could fire late (once the poll catches up). Acceptable: each role bootstraps a
  clean window on first start.
- If two roles process the same merge at slightly different times, the global view
  is briefly inconsistent. The state files are per-role on purpose; consistency
  is eventual and bounded by `poll_interval_sec`.

### Backfill window sizing (added 2026-06-11 after D2 smoke test)

The initial D2 implementation used a 5-minute backfill window. Live smoke test
revealed an edge case: PR #35 merged at `06:19:54Z`, but operator paste latency
plus the manual watcher-reload ritual placed the new watcher start at `06:25:36Z`
— a 5 min 42 s gap. The 5-minute window placed `pr_merged_last_seen_utc` at
`06:20:36Z`, which is **after** the merge timestamp, so `gh pr list --search
"merged:>06:20:36Z"` returned empty for orchestrator and product-manager. Only
`developer`, whose state file already carried a stale-but-earlier timestamp from
a prior probe, captured the event.

Widening the default to **1 hour** absorbs all realistic restart-induced gaps
(operator latency, transient outages, gh-CLI retries) without ever replaying
more than an hour of merge history. The three-layer dedup defense
(`pr_merged_last_seen_utc` + `processed_event_ids` ring + SHA-keyed event ID)
makes any overlap idempotent, so the window can be widened freely. Tests and
short-lived sandboxes can override via `PR_MERGED_BACKFILL="10 minutes ago"` to
keep replay scope tight; D4 (watcher resilience / auto-restart on script change)
will remove the operator-paste latency entirely — at which point the default
could tighten back to ~10 minutes, but 1 hour stays template-grade for any
manually-operated deployment.

**State after this fix:** smoke test on a fresh state file (`pr_merged_last_seen_utc`
deleted) immediately captures PRs merged up to one hour earlier. Both PR #34
and PR #35 are recoverable from the current state and will fan out on the next
poll after watcher reload.

## Verification

Manual smoke test on first deploy:

1. Open and merge a trivial PR (e.g. a README typo fix).
2. Within 60 seconds, observe wake-up prompts in the orchestrator, PM, and
   developer panes containing a `pr_merged` event for the new PR.
3. `cat /var/log/dev-studio/agent-state/developer.json | jq .pr_merged_last_seen_utc`
   matches the merge timestamp.
4. Architect and tester panes do **not** wake (correct exclusion).
5. Trigger a second poll without merging anything new; no duplicate event fires.

## Follow-ups (out of scope)

- **D2.1** Label-conditional fan-out for architect (`needs-design`, path:
  `docs/decisions/**`) and tester (`needs-test`, path: `tests/**`).
- **D2.2** Auto-prune merged-branch in developer's cleanup turn (currently advisory).
- **D2.3** Telegram digest of merges per day for orchestrator (separate channel).
