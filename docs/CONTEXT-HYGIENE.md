# Context Hygiene & Re-priming Doctrine

**Status:** Active
**Scope:** Multi-agent dev studio template
**Owner:** Architect (doctrine updates), Human (operational triggers)

---

## 1. Why This Document Exists

Agents are long-running Claude Code instances. Two slow-burn problems can
silently degrade behavior over multi-day sessions:

1. **Doctrine drift** — A new ADR or role-doc patch is merged to `main`,
   but the agent's loaded system prompt is still the old version. The
   agent keeps acting on stale rules until it's re-primed or restarted.
2. **Post-compaction state drift** — When Claude Code auto-compacts the
   conversation (~200K token threshold), short-term memory of recent
   actions ("I just commented on PR #X") can blur. The role identity
   (CLAUDE.md + role doc) is preserved by the system prompt, but the
   agent should re-read GitHub state instead of trusting its memory.

Note: agent identity does **not** disappear on compaction. CLAUDE.md and
the role doc live in the system prompt slot, which compaction does not
touch. This document is about *aligning to new doctrine* and *trusting
the source of truth*, not about preventing identity loss.

## 2. Single Source of Truth (Doctrine Restatement)

For any operational decision, the agent reads in this priority order:

1. **GitHub** (issues, PRs, labels, comments) — live, always authoritative.
2. **`agent-state.sh` JSON** — local watermark/dedup state, written by the
   watcher loop, never by the agent's chat memory.
3. **CLAUDE.md + role doc** (`.claude/agents/<role>.md`) — identity,
   behavior, doctrine.

The agent **never** acts on its chat history alone. Examples of forbidden
inferences:

- "I think I already commented on this PR." → re-query the PR.
- "The architect probably finished review." → re-read PR labels.
- "Last time the label was X." → re-read the issue.

## 3. When to Re-prime

Trigger a re-prime when any of these is true:

| Trigger | Severity | Action |
|---------|----------|--------|
| New ADR merged to `main` | High | Re-prime all affected roles. |
| Role doc patched on `main` | High | Re-prime that role. |
| `CLAUDE.md` patched on `main` | High | Re-prime **all** roles. |
| Agent visibly confused (wrong label, wrong action) | Critical | Re-prime that role; if no `[REPRIME ACK]` within one polling cycle, full restart (§ 4.2). |
| Routine, end of day | Low | Optional — re-prime any role that worked >4h. |

Compaction itself is **not** a trigger. Compaction is automatic and safe;
re-priming is for *doctrine alignment*, not memory hygiene.

## 4. How to Re-prime

### 4.1 Soft re-prime (default)

```bash
bash scripts/reprime-agent.sh <role>
```

`<role>` is one of: `orchestrator`, `product-manager`, `architect`,
`developer`, `tester`.

This is the **only operation you normally need.** It is fully automatic:

- Sends an enqueued `[REPRIME]` message to the role's tmux pane.
- The agent finishes its in-flight work unit, then re-reads
  `.claude/CLAUDE.md` and its role doc.
- The agent acknowledges with `[REPRIME ACK] <role>: <summary>` and
  resumes under the refreshed doctrine.
- **No human action between send and ack.** No restart, no manual relaunch.

See § 5 for the timing & work-in-progress contract.

### 4.2 Full session restart (fallback, rare)

Use only when:

- Soft re-prime did not produce `[REPRIME ACK]` within one polling cycle, OR
- Multiple agents are confused at once and you cannot wait, OR
- The tmux session itself is broken (panes died, watchers detached, etc.).

```bash
bash scripts/dev-studio-start.sh stop
bash scripts/dev-studio-start.sh start
```

This kills all 5 agents and respawns the whole session cleanly. There is
**no per-role restart**, by design — the launcher only exposes
`start | attach | stop`. We do not add a per-role kill path because
"selective restart" historically causes more drift bugs than it fixes
("çalışan şeyi bozmayalım").

There is no manual relaunch step. The launcher handles everything.

## 5. Re-prime Timing & Work-in-progress

Soft re-prime is **enqueued**, never interrupting. The contract:

1. The re-prime message is queued as the agent's next chat input.
2. The agent finishes its **current conversation turn** (usually seconds).
3. If the agent is mid-way through a larger work unit (writing a PR,
   running tests, drafting an ADR), it completes that work unit too.
   The re-prime applies on the **next** task start.
4. The agent acknowledges with `[REPRIME ACK] <role>: <summary>`, then
   proceeds with the new doctrine in effect.

**This means:**
- ✅ No work is lost or left half-done.
- ✅ The re-prime always takes effect before the agent's next decision.
- ⚠️ If the agent is in the middle of a long task (e.g. a 20-minute
  story implementation), the re-prime may apply 20 minutes later.

If you cannot wait, escalate to full restart (§ 4.2) — but understand
that full restart abandons all in-flight work across all 5 agents.

## 6. Context Watchdog (Automated Re-prime)

### 6.1 Why a watchdog exists

Claude Code advertises auto-compaction when conversation length approaches
the model's context window. **In sustained-load multi-agent sessions we
have repeatedly observed this failing to trigger.** Agents pile up to
`100% context used` (visible in the Claude Code status line) and stay
there — answering occasional questions but unable to ingest new doctrine,
ADRs, or sprint guidance. They drift.

The Context Watchdog closes this gap by **deterministically** firing
`/compact` (a real Claude Code slash command) followed by a re-prime
message when an agent's context usage crosses a configurable threshold.
It does **not** replace Claude Code's auto-compact — it backstops it.

### 6.2 Components

| File | Role |
|------|------|
| `scripts/agent-context-monitor.sh` | Polls every pane, decides who needs reprime |
| `scripts/reprime-agent.sh` | Sends `/compact` + re-prime message (called by monitor) |
| `scripts/agent-journal.sh` | JSON-Lines facts journal (append / summary / rotate) |
| `systemd/dev-studio-context-monitor@.service` | Oneshot — runs the monitor |
| `systemd/dev-studio-context-monitor@.timer` | Fires the service every 60s |

### 6.3 Decision logic (per agent, per tick)

```
read `% context used` from tmux pane (last ~2000 lines)
  └─ if absent: log "no reading", skip

if pct < THRESHOLD_PCT (default 85):
  if previously critical: clear last_critical_seen_utc
  log OK and continue

if pane is busy ("Worked for...", "Cogitated for...",
                 "Compacting conversation", etc.):
  log busy-skip → retry next cycle

if within COOLDOWN_MIN (default 10) of previous reprime:
  log cooldown-skip

else:
  fire reprime-agent.sh <role>
  → /compact + Enter + 3s sleep
  → multi-line reprime message via tmux load-buffer + paste-buffer
  → agent-journal.sh append context_alert + reprime
```

### 6.4 Tunables (override via systemd drop-in)

| Env | Default | Meaning |
|-----|---------|---------|
| `THRESHOLD_PCT` | 85 | Fire reprime at or above this % |
| `CRITICAL_PCT` | 100 | Sustained-critical floor |
| `CRITICAL_SUSTAIN_MIN` | 5 | Minutes at CRITICAL before warning |
| `COOLDOWN_MIN` | 10 | Minimum gap between reprimes per role |

Override with: `systemctl --user edit dev-studio-context-monitor@<PROJECT>.service`

### 6.5 Journal (`agent-journal.sh`)

- **Write-only by the system** — agents NEVER write to the journal.
  This is a deliberate drift-safety guarantee: an agent that misreads
  facts cannot retroactively rewrite them.
- **JSON Lines** at `/var/log/dev-studio/<PROJECT>/journal/facts-YYYY-MM-DD.jsonl`
  (falls back to `~/.dev-studio/<PROJECT>/journal/` if `/var/log` is
  unwritable).
- **Schema:** `{ts, type, role, ref, fact, value}` — flock-protected
  against concurrent appends from monitor + reprime invocations.
- **Reprime message reads the journal** — last 6h, role-scoped — and
  attaches a summary at the top of the message so the agent wakes with
  situational context.

### 6.6 What gets logged

Every reprime decision appears in the journal:

```jsonl
{"ts":"...","type":"context_alert","role":"architect","ref":"watchdog","fact":"context_pct_before","value":"100"}
{"ts":"...","type":"reprime","role":"architect","ref":"manual-or-watchdog","fact":"compacted=yes","value":""}
{"ts":"...","type":"reprime","role":"architect","ref":"watchdog","fact":"fired","value":"ok"}
```

This gives the operator a complete audit trail of which agent was
reprimed when, and why.

### 6.7 Installation

Handled automatically by `scripts/install/dev-studio-install-systemd.sh`.
After project bootstrap the timer is enabled and starts firing within
30 seconds.

## 7. What Does NOT Need Re-priming

- Minor PR comment exchanges.
- Scheduled idle time (agent does nothing → cannot drift).
- Token rate-limit pauses (Claude Code resumes correctly).

> Previous versions of this doc listed "compaction events (auto-handled
> by Claude Code)" here. That assumption proved unsafe under sustained
> multi-agent load — see § 6.1. The Context Watchdog now backstops it.

## 8. Agent-side Protocol

Each role doc (`.claude/agents/*.md`) carries a **REPRIME Protocol**
section that defines exactly how an agent must respond when it receives
a `[REPRIME]` message. The expected acknowledgment format is:

```
[REPRIME ACK] <role>: <one-line summary of any doctrine change noticed, or "no change">
```

If you do not see this acknowledgment within one polling cycle, escalate
to full restart (§ 4.2).

---

## See Also

- `scripts/reprime-agent.sh` — implementation (soft re-prime + `/compact`).
- `scripts/agent-context-monitor.sh` — Context Watchdog poller.
- `scripts/agent-journal.sh` — facts journal helper.
- `scripts/dev-studio-start.sh` — launcher (full restart path).
- `systemd/dev-studio-context-monitor@.{service,timer}` — watchdog units.
- `.claude/agents/*.md` — per-role REPRIME Protocol section.
- `docs/decisions/` — ADRs that may trigger re-prime when merged.
- `.claude/CLAUDE.md` — agent identity & project context.
