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

record pct snapshot in state (stamp last_pct_change_utc only if
  we have a prior observation AND pct differs from prev)

if pct < THRESHOLD_PCT (default 85):
  if previously critical: clear last_critical_seen_utc
  log OK and continue

use_clear = 0

if pane shows API overflow error  →  use_clear = 1
  ("context window exceeds limit", "context_length_exceeded",
   "prompt is too long", "API Error: 400 invalid params")
  log api_overflow event

elif pane is busy ("Worked for...", "Cogitated for...",
                   "Compacting conversation", etc.):
  if pane is likely STUCK:
    if pct >= CRITICAL_PCT: window = STUCK_AFTER_MIN_CRITICAL (3 min)
    else:                   window = STUCK_AFTER_MIN          (20 min)
    stuck = (now - last_reprime_utc) >= window
            AND last_pct_change_utc <= last_reprime_utc
    if stuck and ESCALATE_STUCK_TO_CLEAR=1:
      use_clear = 1
      log stuck_override event
  else:
    log busy_skip → retry next cycle

if within COOLDOWN_MIN (default 10) of previous reprime:
  if use_clear == 0: log cooldown_skip and return
  else:              log cooldown_bypass (stuck/overflow forces through)

else:
  fire reprime-agent.sh <role>
    with REPRIME_USE_CLEAR=1 if use_clear==1
  → Esc (clear any UI overlay / pending input)
  → /compact (soft) OR /clear (hard) + defensive Enter/Escape
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
| `STUCK_AFTER_MIN` | 20 | Minutes of frozen pct (pct < 100%) before declaring the pane stuck |
| `STUCK_AFTER_MIN_CRITICAL` | 3 | Tighter stuck window when pct >= CRITICAL_PCT (`/compact` should land in under a minute) |
| `ESCALATE_STUCK_TO_CLEAR` | 1 | When a pane is stuck, escalate from `/compact` to `/clear` (hard reset) |

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

Additional `fact` values introduced by the stuck-pane override:

| Fact | When |
|------|------|
| `busy_skip` | Pane is busy and not yet stuck — skipped this cycle |
| `stuck_override` | Pane is busy AND stuck (frozen pct past the threshold) — busy_skip bypassed |
| `api_overflow` | Pane shows a context-window-exceeded error — `/clear` is forced |
| `cooldown_skip` | Within COOLDOWN_MIN of previous reprime — nothing fired |
| `cooldown_bypass` | Cooldown active but `use_clear=1` forced the reprime through anyway |
| `cleared=yes` | The reprime sent `/clear` (hard reset) instead of `/compact` |

This gives the operator a complete audit trail of which agent was
reprimed when, and why.

### 6.7 Installation

Handled automatically by `scripts/install/dev-studio-install-systemd.sh`.
After project bootstrap the timer is enabled and starts firing within
30 seconds.

### 6.8 Stuck-pane / API-overflow override

`agent_is_busy()` reads the pane's last 5 lines and looks for progress
phrases like `Worked for Ns`, `Cogitated for Ns`, `Crunched for Ns`, or
`Compacting conversation`. This protects active reasoning from being
interrupted by a reprime mid-turn.

However, a **frozen pane** keeps the last `Worked for Ns` line in its
scrollback indefinitely — the agent is no longer making progress, but the
watchdog interprets the stale text as "currently busy" and never fires a
reprime. We observed real cases where PM and tester sat at 100% for 3+
hours with `busy_skip` written every cycle.

Two independent detectors break this deadlock:

1. **`agent_likely_stuck`** — the pane is busy AND:
   - `now - last_reprime_utc` ≥ the stuck threshold (`STUCK_AFTER_MIN_CRITICAL`
     when `pct >= CRITICAL_PCT`, else `STUCK_AFTER_MIN`), AND
   - `last_pct_change_utc <= last_reprime_utc` (the pct has not moved since
     the last reprime stamped it).

   Critical-pct uses a tighter 3-minute window because `/compact` should
   land within ~30-90s; if it has not moved the needle in 3 minutes,
   `/compact` failed and only `/clear` can recover. Below 100%, slower
   progress is tolerated for up to 20 minutes.

2. **`agent_api_overflow`** — grep for `context window exceeds limit`,
   `context_length_exceeded`, `prompt is too long`, or
   `API Error: 400 invalid params` in the last 20 lines. When this
   appears, `/compact` literally cannot recover; only `/clear` (which
   wipes history) works.

When either detector trips, the watchdog calls `reprime-agent.sh` with
`REPRIME_USE_CLEAR=1`. The reprime script then:

- Sends `Esc` first to clear any UI overlay or half-typed prompt.
- Sends `/clear` instead of `/compact`.
- Defensively sends an extra `Enter` and `Escape` to dismiss any "Are
  you sure?" confirmation some Claude Code builds show on `/clear`.
- Pastes the full reprime message, which instructs the agent to re-read
  `CLAUDE.md`, the role doc, and the kickoff template — since `/clear`
  wipes conversation history entirely, kickoff doctrine must be restored.

Cooldown is bypassed when `use_clear=1`. Pathological states (stuck or
overflow) should not wait another 10-minute cooldown window.

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
