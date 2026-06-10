# ADR-0002: GitHub-native autonomy — work queue, wake-up, and inter-agent transport

- **Status**: Accepted
- **Date**: 2026-06-10
- **Deciders**: @architect, @atilcan65 (human owner)
- **Supersedes**: —
- **Related**: ADR-0001, `.claude/CLAUDE.md` §Auto-Ping Hard-Rule, `scripts/notify.sh`, `scripts/agent-watch.sh`

## Context

After the Auto-Ping Hard-Rule landed (PR #21) we observed a structural gap:

- `scripts/notify.sh -l <role>` pushes a line to **Telegram**.
- Telegram is read by the **human owner**, not by Claude Code agent instances.
- Therefore "Agent A pings Agent B" ended at the human's eye — the human had to paste a prompt into Agent B's pane for B to react.
- This made the human a **silent courier**, defeating the autonomy goal and violating the spirit of CLAUDE.md §Auto-Ping Hard-Rule ("Never ask the human to relay a message to another agent").

We need an inter-agent transport that:

1. Has no human in the read path.
2. Survives agent restarts (durable state of truth).
3. Is auditable after the fact.
4. Generalises to any future project that copies this `.claude/` template.
5. Stays inside tools every agent already runs (`gh`, `git`).

A bespoke message bus (Redis, Kafka, NATS, even a local SQLite queue) fails criterion 4 — it adds infrastructure that the template would have to bootstrap on every new project's VM. A file-based JSONL inbox fails criterion 2 and 3 (lost on disk wipe, no PR-level audit).

## Decision

We adopt **GitHub itself as the autonomy substrate**. Every wake-up signal, work assignment, and inter-agent handoff is expressed as a **GitHub artefact**:

| Signal | GitHub artefact | How an agent detects it |
|---|---|---|
| "You have a new story" | Issue with label `agent:<role>` + `status:ready` | `gh issue list --label "agent:<role>" --label "status:ready"` |
| "You are reviewing a PR" | PR with label `cc:<role>` or comment mentioning `@<role>` | `gh pr list --label "cc:<role>"`, `gh pr view --json comments` |
| "You are blocked by another agent" | Issue/PR comment from peer mentioning `@<role>` + a directive line | comment scan with timestamp diff |
| "State changed" | Label transition (`status:in-progress` → `status:in-review` → `status:done`) | `gh issue view --json labels`, diff against last known state |

Agents run a **polling loop** that wakes them every 60 seconds. The loop:

1. Reads `/var/log/dev-studio/agent-state/<role>.json` for the last-seen timestamp and processed event IDs.
2. Queries GitHub with the role-specific filters (above table).
3. Filters out already-processed events.
4. Takes action on the new event (start a story, file a review comment, hand off).
5. Updates the state file.
6. Sleeps 60s, repeats.

Telegram is **retained** — but its semantic role is narrowed to **human-visible monitoring**, not agent transport. Every `scripts/notify.sh` call is mirrored as a GitHub artefact (the line that actually wakes a peer).

## Rationale

### Why GitHub as the substrate

- **Already the state of truth for the work itself.** Issues hold stories, PRs hold work, labels hold status. Co-locating wake-up signals here removes a class of "the issue says X but the message bus says Y" bugs.
- **`gh` is on every dev VM the template targets.** No new daemon, no new port, no new auth surface.
- **Free audit trail.** Every wake-up is a label change, a comment, an assignment. After-action review is `gh issue view <n> --json events` away.
- **Survives restarts.** If a Claude Code pane dies and is relaunched 6 hours later, the polling loop catches up from the state file's `last_seen` timestamp.
- **Generalises to any project.** A new repo gets `.claude/`, `scripts/agent-watch.sh`, the standard label set, and the same autonomy works.

### Why labels, not assignees

GitHub PRs/issues take real user logins as assignees. We do **not** create separate GitHub user accounts for each role (we considered it; it would cost N seats per project and complicate token management). Instead we use the existing `agent:<role>` label set as the assignment primitive. The human owner remains the only real GitHub user on the repo.

The trade-off: `gh issue list --assignee @me` doesn't disambiguate roles. We use `--label "agent:<role>"` filters instead. Every agent's wake-up query is parameterised by its role label.

### Why 60-second polling

- **Too fast (<30s)** burns GitHub API quota. The unauthenticated quota is 60 req/h; the authenticated quota is 5000 req/h. Five agents polling every 30s = 600 req/h, well within budget but leaves no headroom for `gh pr view`, `gh issue create`, etc.
- **Too slow (>5min)** breaks the "Tester PRs draft, Developer fixes it" hot path.
- **60s** is the sweet spot: 5 agents × 1 req/min × 60 min = 300 req/h baseline. Plenty of headroom for the actual work.
- The number is a knob, not a constant. Each agent reads `AGENT_POLL_INTERVAL_SEC` from env (default 60).

### Why a state file per agent

- Crash recovery: a Claude Code restart re-reads `last_seen` and skips events it already handled.
- Idempotency: the `processed_event_ids` set prevents acting twice on the same comment if its timestamp didn't move.
- Debuggability: `cat /var/log/dev-studio/agent-state/developer.json` shows exactly what the developer last saw.

### Why we keep `notify.sh` (Telegram) at all

- The human owner needs *one* feed that summarises every agent decision and tells them when a `→HUMAN` escalation needs them.
- Removing it would force the human to refresh GitHub manually.
- We do **not** retire `notify.sh`; we narrow its purpose. The new rule: *every* outbound auto-ping is **both** a `notify.sh` call (for the human) **and** a GitHub artefact (for the peer). The peer reads the artefact; the human reads the Telegram message.

### Alternatives rejected

| Alternative | Why rejected |
|---|---|
| File-based JSONL inbox + `tail -f` in each pane | No durable audit; lost on VM rebuild; no PR-level trace; tail-f-into-claude integration is fragile |
| Real GitHub user per agent (5 accounts) | Seat cost; token management cost; assignee-based queries gain little over label-based |
| Redis/SQLite local queue | Adds infrastructure to the template bootstrap; new failure mode (queue down); no GitHub audit trail |
| Webhook-driven (GitHub webhooks → local listener) | Requires public endpoint or tunnel; bootstrap cost is high; overkill for 5-agent project |
| Telegram-only with agents polling Telegram | Agents are not Telegram clients; would need bot-side message routing per role; complex |

## Consequences

### Positive
- Human exits the relay loop. Autonomy goal achieved.
- Wake-up events are auditable, durable, idempotent.
- Template ports to any new project with one `.claude/` copy plus the standard label set.
- Inter-agent comms inherit GitHub's strengths: rate limits, ACL, history.

### Negative
- **60-second p95 latency** between "Agent A handoff" and "Agent B picks up". For the kind of work we're doing this is acceptable; for sub-second comms it would not be.
- **GitHub outage = autonomy outage.** When GitHub is down the agents block. Acceptable: when GitHub is down we cannot ship anyway.
- **API quota awareness becomes a thing agents must track.** Mitigated by 60s polling and per-agent state caching.

### Required changes
1. **New**: `scripts/agent-watch.sh` — the wake-up helper (query + state diff + JSON emit).
2. **New**: `scripts/agent-state.sh` — init/read/write helper for the JSON state files.
3. **New**: `/var/log/dev-studio/agent-state/` directory, owned by the agent user.
4. **CLAUDE.md**: §Autonomy Loop section added (the canonical loop spec).
5. **Each `.claude/agents/<role>.md`**: §Auto-poll triggers section added (role-specific filters).
6. **Standard label set**: must include `agent:<role>` (5 labels), `status:ready|in-progress|in-review|blocked|done`, `cc:<role>` (5 labels) for review fanout.
7. **`scripts/notify.sh`**: unchanged in code; doctrine updated — every call must be paired with a GitHub artefact that the peer can detect.

### Migration
- Sprint 1 is mid-flight. We land this in a single PR (`chore/github-native-autonomy`) without touching in-flight stories.
- Agents reload souls after merge (the standard "soul reload" prompt).
- The very next sprint kickoff exercises the new autonomy end-to-end.

### Open questions, deferred
- **Cross-repo handoff.** When a future project depends on this template living in another repo, the label conventions must travel. We document the label set in this ADR; a future ADR can address cross-repo if it becomes real.
- **Burst-mode polling.** When an agent is in the middle of an active conversation (a PR review thread heating up) the 60s polling is too slow. Future enhancement: an agent currently mid-task can set its poll interval to 15s for the next 5 minutes via a state flag.

## Notes for future projects (template use)

If you're copying this template to a new project:

1. Copy `.claude/`, `scripts/agent-watch.sh`, `scripts/agent-state.sh`, `scripts/notify.sh`, and `scripts/dev-studio-start.sh`.
2. On the new repo, create the standard label set (script: `scripts/bootstrap-labels.sh` — see follow-up).
3. Ensure `/var/log/dev-studio/agent-state/` exists and is owned by the agent user (handled by the launcher).
4. Set the GitHub PAT or `gh auth login` for the agent user on the new VM.
5. Adjust `AGENT_POLL_INTERVAL_SEC` if the project's tempo is different (research projects: 5min; live-incident response: 15s).

The label set, the polling loop, the state files, and the `notify.sh` contract are **template-level invariants**. Project-specific tuning lives in env vars and the project's own `CLAUDE.md`.
