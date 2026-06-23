# scripts/

Operational scripts for Dev Studio.

## notify.sh — Telegram notifications

Sends notifications to Telegram via Bot API.

### Setup

1. Create a Telegram bot via [@BotFather](https://t.me/BotFather), copy the token.
2. Get your chat ID (DM `@userinfobot` or use `getUpdates` for groups).
3. Add to `~/.dev-studio-env`:

       export TELEGRAM_BOT_TOKEN="..."
       export TELEGRAM_CHAT_ID="..."

4. `chmod 600 ~/.dev-studio-env`
5. Source from `~/.bashrc`: `[ -f ~/.dev-studio-env ] && source ~/.dev-studio-env`

### Usage

    ./scripts/notify.sh "Plain message"
    ./scripts/notify.sh -l info "Sprint 1 started"
    ./scripts/notify.sh -l warn "CI flaky on PR #42"
    ./scripts/notify.sh -l error "P0 blocker: prod down"
    ./scripts/notify.sh -l ok "Deploy succeeded"

### Levels

| Flag | Icon | When |
|------|------|------|
| info (default) | ℹ️ | Standard updates |
| warn | ⚠️ | Non-blocking issues |
| error | 🚨 | P0/P1 blockers, paging |
| ok | ✅ | Success confirmations |

### Used by

- `.claude/agents/orchestrator.md` — Escalation on blockers
- `.claude/commands/standup.md` — Daily standup digest
- `scripts/health-check.sh` (planned) — Agent heartbeat alerts
- `systemd/dev-studio-health.timer` (planned) — 30-min health check

---

## claim-next-ready.sh — Auto-Claim Protocol (Issue #272 / ADR-0038 §Layer 2)

Self-claim helper called by `agent-watch.sh` after events processed. Each agent
role runs `bash scripts/claim-next-ready.sh <role>` whenever `WIP_count_for_<role> < 2`
(see `.claude/agents/<role>.md` §Auto-Claim Protocol). Closes the
"assigned-but-never-picks-up" RCA-19 family gap (Issue #222, 2026-06-22 dev
8h 42min idle incident).

### What it does

1. Lists open issues with `agent:<role>` AND `status:ready`.
2. Sorts: priority (P0 > P1 > P2 > P3) > age (oldest first).
3. Skips items with `depends on #N` / `blocked by #N` where #N is open.
4. Atomically flips the top item: `status:ready → status:in-progress`.
5. Posts audit comment + writes `/var/log/dev-studio/<project>/auto-claim.log`.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Claimed (issue #N flipped to `status:in-progress`) |
| 1 | Nothing to claim (no ready items, or all blocked by open deps) |
| 2 | Invalid role argument |
| 3 | WIP limit reached (≥2 `status:in-progress` items already) |
| 4 | gh API error (network/auth) |

### Usage

    bash scripts/claim-next-ready.sh developer   # role = developer
    bash scripts/claim-next-ready.sh architect   # role = architect

### Disable (kill switch)

Set `CLAIM_NEXT_READY_ENABLED=false` env var to bypass the auto-claim hook in
`agent-watch.sh` (the hook checks this var before calling the script).

### Regression coverage

`scripts/tests/d031-claim-next-ready.sh` — 8 TCs (priority sort, age tie-break,
dependency skip, WIP cap, negative, usage, invalid role, audit log).

### Reference

- ADR-0038 §Layer 2 (claim helper contract)
- Issue #271 (doctrine gap "no initiative" pattern)
- Issue #272 (this template port)
- Sister script in AtilCalculator: `scripts/claim-next-ready.sh` (PR #286)
