# ADR-0003 — Event Model v2 (template-grade silent-failure prevention)

**Status:** Accepted
**Date:** 2026-06-10
**Builds on:** ADR-0002 (GitHub-Native Autonomy)
**Supersedes:** event-model section of ADR-0002

## Context

ADR-0002 established GitHub as the single source of truth for the work queue and
introduced `agent-watch.sh` to poll for state changes and wake the relevant
tmux pane. The v1 event model proved insufficient in production:

**Silent-failure incident (2026-06-10, PR #26 / tester):**
- Developer pushed commit `a3fbe2f` to fix a SIGTERM handler bug.
- Architect re-reviewed, removed `cc:architect`, kept `cc:tester`.
- Tester watcher polled every 60s for ~10 minutes — `new_events: []` every time.
- Tester pane never woke up. Operator had to manually diagnose via screenshots.

**Root cause:** v1 event ID for a PR review was
`pr-review-<num>-<updatedAt>`. The PR's `updatedAt` had advanced during the
architect's label flip, the tester's watcher processed that event, then
`last_seen_utc` advanced to a timestamp after the architect's activity. When
the developer pushed a new commit, GitHub's `updatedAt` did not always advance
past `last_seen_utc` in a way that produced a new event ID — and even when it
did, the dedup key was timestamp-based, not content-based. **A new
testable artifact (a new commit) did not produce a new event.**

Five structural gaps in v1:

1. **No "new commit on assigned PR" event.** The exact handoff the system
   exists to enable (developer fix → tester re-verify) had no dedicated event.
2. **`processed_event_ids` grows unbounded.** Over weeks of runtime this
   slows JSON parsing and bloats RAM.
3. **No liveness signal.** A dead watcher (network glitch, OOM, processed-id
   corruption) is invisible until a human notices "agent X isn't working."
4. **No deadlock breaker.** If any event is lost, the PR sits with
   `cc:<role>` forever — no retry, no escalation.
5. **No one-command diagnosis.** Operator must SSH, read three logs, parse
   JSON state files, and reason about timestamps to find the cause.

This is unacceptable for template-grade infrastructure that must be reusable
across future projects without recurring babysitting.

## Decision

Adopt **Event Model v2** with five guarantees, implemented across
`agent-watch.sh`, `agent-state.sh`, and a new `agent-doctor.sh`.

### Guarantee 1 — Content-addressed event IDs for PR work

PR review events now include the head commit SHA:

```
pr-review-<num>-<sha7>-<updatedAt>
```

A new push to a PR where `cc:<role>` is active produces a new event ID,
guaranteed, even if `updatedAt` is identical or earlier than `last_seen_utc`.

Additionally, a dedicated event collector emits:

```
pr-commit-<num>-<sha7>
```

whenever a PR carries `cc:<role>` and the head SHA has not been processed yet.
This is the canonical "agent X must re-verify this PR" wake-up.

### Guarantee 2 — Deadlock-breaker via stale-cc detector

If a PR has carried `cc:<role>` for longer than `STALE_CC_SEC` (default 900s
= 15 min) without any state change, the watcher emits:

```
stale-cc-<num>-<sha7>-b<5min-bucket>
```

The agent receives a wake-up prompt explaining "you've been holding this PR
for >15 min — act or punt." The 5-minute bucket prevents spam while
guaranteeing eventual re-wake.

This makes permanent stalls structurally impossible. Any lost event,
crashed watcher, or `tmux send-keys` race resolves within 15 min.

### Guarantee 3 — Bounded `processed_event_ids` (TTL trim)

After every poll, the state file is trimmed:

```
processed_event_ids = processed_event_ids[-50:]
```

50 entries cover hours of activity even at burst. Trimming is FIFO so the
most recent dedup window is always intact. Old entries naturally age out;
any event that re-fires after >50 newer events have passed will wake the
agent again (acceptable — by then the situation has changed).

### Guarantee 4 — Heartbeat + stale-watcher alert

Every watcher loop iteration calls `agent-state.sh heartbeat <role>` before
running queries. This writes `last_heartbeat_utc` independently of
`last_seen_utc` (which is event-driven).

`agent-doctor.sh --alert` (run via cron every 5 min) checks every role's
heartbeat. Any role with `last_heartbeat_utc > 300s ago` triggers a
Telegram warn via `notify.sh`. **Silent watcher death is impossible to miss.**

### Guarantee 5 — One-command diagnosis (`agent-doctor.sh`)

```
agent-doctor.sh                       # health board for all 5 roles
agent-doctor.sh <role>                # deep dive: state, recent polls, cc PRs, hints
agent-doctor.sh <role> --kick <pat>   # surgical dedup removal
agent-doctor.sh --alert               # cron-friendly stale check
```

When something does go wrong, the operator runs one command and gets:
- Watcher PID status (alive/dead)
- Heartbeat age (colour-coded)
- Dedup list size
- cc:<role> PR count
- Recent poll outcomes
- **Specific unblock suggestions** including the exact `--kick` pattern

No more screenshot chains.

## New event types

| Kind | ID format | Trigger | Notes |
|---|---|---|---|
| `issue_assigned` | `issue-assigned-<n>-<updatedAt>` | label `agent:<role>` + open + updatedAt > last_seen | v1, unchanged |
| `pr_review_requested` | `pr-review-<n>-<sha7>-<updatedAt>` | label `cc:<role>` + open | **v2: SHA added** |
| `pr_new_commit` | `pr-commit-<n>-<sha7>` | label `cc:<role>` + new head SHA | **v2 new** |
| `pr_comment_mention` | `pr-mention-<n>-<comment_id>` | `@<role>` in comment/review body | v1, unchanged |
| `stale_cc` | `stale-cc-<n>-<sha7>-b<bucket>` | cc:<role> unchanged > STALE_CC_SEC | **v2 new** |
| `label_change` | `board-<n>-<updatedAt>` | orchestrator only — any open issue/PR change | v1, unchanged |

## Operational matrix

| Failure mode | v1 outcome | v2 outcome |
|---|---|---|
| Developer pushes new commit on `cc:tester` PR | **silent stall** | `pr_new_commit` event fires within 60s |
| Watcher daemon crashes | invisible until operator notices | Telegram warn within 5 min |
| Event lost (tmux race, network glitch) | permanent stall | `stale_cc` event within 15 min |
| `processed_event_ids` corruption | manual JSON edit required | `agent-doctor.sh <role> --kick <pattern>` |
| Operator asks "why isn't X waking?" | SSH + 3 logs + JSON parse | one command, ~3 lines of output |
| State file grows for weeks | slow JSON parse | trimmed to 50 entries per poll |

## Implementation files

- `scripts/agent-watch.sh` — adds `query_new_commits_on_assigned_prs`,
  `query_stale_cc`, calls `heartbeat` + `trim` per poll, includes SHA in
  `pr-review` IDs.
- `scripts/agent-state.sh` — adds `heartbeat`, `trim`, `kick`, `stale`
  subcommands; backfills `last_heartbeat_utc` on existing state files.
- `scripts/agent-doctor.sh` — new file; health board, deep dive, kick, alert.
- `docs/decisions/ADR-0003-event-model-v2.md` — this doc.

## Cron suggestion (operator setup)

```
*/5 * * * * /opt/dev-studio/atilprojects/scripts/agent-doctor.sh --alert
```

Five-minute cadence balances responsiveness against Telegram noise.

## Consequences

**Positive:**
- The exact 2026-06-10 PR #26 incident is structurally impossible.
- Future projects copy this directory and inherit all five guarantees.
- Mean-time-to-diagnose drops from ~10 min (screenshot chain) to ~5 s.
- State files are size-bounded — months of uptime is safe.

**Trade-offs:**
- `query_stale_cc` adds one `gh pr list` call per poll per role (~5×/min total).
  Acceptable — gh's local rate budget is ~5000 req/hour, we use <300/hour.
- `pr_new_commit` may fire alongside `pr_review_requested` for the same SHA
  — `unique_by(.id)` in `poll_once` handles dedup; both event IDs are
  intentionally distinct so neither is lost if the other fails.
- `agent-doctor.sh --alert` requires `notify.sh` configured with
  `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` (already in `~/.dev-studio-env`).

**Migration:**
- Existing state files auto-backfill `last_heartbeat_utc` on next watcher
  start via `cmd_init`'s field check.
- No state file deletion or reset required.
- Watcher restart (`dev-studio-start.sh restart`) picks up v2 atomically.

## Template-grade reuse

When forking this infrastructure for a new project:
1. Copy `scripts/agent-{watch,state,doctor}.sh` and `notify.sh`.
2. Copy `docs/decisions/ADR-0002-*.md` + `ADR-0003-event-model-v2.md`.
3. Adjust the role list in `agent-doctor.sh` (`ROLES=(...)`) if the
   project uses different agent roles.
4. Configure `~/.dev-studio-env` with Telegram creds.
5. Add the `agent-doctor.sh --alert` cron.

Total bootstrap: ~10 min, zero project-specific event-model design needed.
