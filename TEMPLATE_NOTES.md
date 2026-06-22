# Template Notes — Sprint 4 Lessons Captured

> This file captures learnings from AtilCalculator's Sprint 4 that are
> ported to the template, but are NOT general enough for an ADR or
> per-soul doctrine. It's a Sprint-4 retrospective summary specific to
> the template evolution.
>
> Refs: Sprint 4 retro, ADR-0002, ADR-0033 (Auto-Ping dual-channel),
> Issue #221 (impl), Issue #222 (template port), #256 (no-standby
> text in wake_nudge).

## Sprint 4 P0: Auto-Ping dual-channel (ADR-0033, Issue #221 → template Issue #222)

**Lesson**: Telegram-only pings leave peer agents asleep until their next
`agent-watch.sh` poll (default 60s, configurable). For an urgent handoff
("PR #N ready for review", "fix pushed, re-review please", "blocker, need
ADR"), 60s is too long.

**Fix**: dual-channel — `notify.sh -w -r <role>` posts to Telegram AND
injects a wake prompt into the target agent's tmux pane via
`scripts/agent-wake.sh`. Peer agent wakes instantly, doesn't have to wait
for the next poll cycle.

**Files**:
- `scripts/agent-wake.sh` — standalone CLI, role → tmux pane mapping
- `scripts/notify.sh` — `-w` / `-r` flags added; dual-channel wired in
- `scripts/tests/d024-agent-wake.sh` — 7-TC regression test
- `.claude/CLAUDE.md.tmpl` — §Auto-Ping Hard-Rule updated
- `.claude/agents/developer.md.tmpl` — Auto-Ping section updated

**When to use `-w`**: acil handoff (PR ready for review, fix pushed,
blocker, ADR needed). NOT for broadcast / bilgilendirme — Telegram
alone is enough.

**When NOT to use `-w`**: peer agent is silent / not running, or this is
a broadcast ping. GitHub artefact (label / comment) is enough.

**Reference impl**: `atilcan65/AtilCalculator` commit `ecbf21a` (PR #239).

## Sprint 4 P0: No-standby doctrine (Issue #238 → template Issue #40)

**Lesson**: agents self-standby on dependency / rate-limit / state
corruption / no-events despite an existing §Doctrine Reminder. The
3-bullet reminder told agents to **do** things but did not enumerate
the **forbidden self-justifications** that look like work pauses
("blocked on X", "rate limit hit", "queue is empty", "waiting for
human").

**Fix**: replace §Doctrine Reminder with a 4-row forbidden-pause table
+ 3-question self-check + per-role callout. Adds `d028-no-standby`
regression test (4 TCs, one per forbidden mode).

**Reference impl**: `atilcan65/AtilCalculator` Issue #238, PR #245.

## Sprint 4 P0: Wake-nudge text must not say "standby" (Issue #256 → template Issue #41)

**Lesson**: the wake_nudge payload's instruction text was `"Lütfen
pickup et: review yap, label flip et, peer'i bilgilendir, sonra
standby."` — the word "standby" instructs the agent to enter standby
mode, directly contradicting the no-standby doctrine.

**Fix**: replace "standby" with "heartbeat yaz ve queue'ya dön" (write
heartbeat + return to queue). Locked in by d015 + d028 regression
suite.

**Reference impl**: `atilcan65/AtilCalculator` Issue #256, PR #257.

## Sprint 4 P2: Proactive board scan (Issue #44 → template Issue #TBD)

**Lesson**: 60s polling cadence means a fresh issue/PR waits up to 60s
before any agent notices. For high-priority issues (P0), that's a
deadline.

**Fix**: `scripts/proactive-board-scan.sh` — every 5 min, each agent
scans its own lane for items in `status:ready` past a freshness
threshold. Adds `d094-ext` regression test (6 TCs).

**Reference impl**: `atilcan65/AtilCalculator` Issue #44, PR #219.
