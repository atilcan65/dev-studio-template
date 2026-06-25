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

---

## d-test convention — `scripts/tests/dNNN-*.sh` (ADR-0046)

Regression tests for shell-script / integration / doctrine-level behavior.
**One file = one bug class.** File name encodes the bug class + number;
header narrative explains the bug, root cause, and fix PR. Canonical pattern
codified in [ADR-0046](../docs/decisions/ADR-0046-d-test-convention.md).

### File naming

    scripts/tests/dNNN-<short-kebab-slug>.sh

- `NNN` — 3-digit zero-padded monotonic integer (gaps allowed).
- `<short-kebab-slug>` — kebab-case, ≤ 40 chars, lowercase, no underscores.
- Grep next free number: `ls scripts/tests/d[0-9]* | sort -V`

### Authoring rules (TL;DR — full rules in ADR-0046)

1. **One file per bug class.** Never bundle two regressions.
2. **First line `set -uo pipefail`** (NOT `-e` — assertions must run after
   a `grep` returns 1).
3. **Standalone runnable**: `bash scripts/tests/dNNN-<slug>.sh` works from
   a fresh clone, no env vars, no fixtures in `/tmp`, no network.
4. **Cross-repo sister-test comment** when porting from AtilCalculator
   (`# Sister test: atilcan65/AtilCalculator scripts/tests/dNNN-<slug>.sh`).
   Use the same `NNN` number for traceability.
5. **TDD red-first**: author the failing assertion, observe the failure,
   THEN write the fix. Document the pre-change failure in the header.
6. **Do NOT write a d-test for** unit-level business logic (use `pytest`),
   one-off CLI scripts, or behavior already covered by another d-test.

### Body skeleton

```bash
#!/usr/bin/env bash
# dNNN-<slug>.sh — regression test for Issue #N | PR #N
#
# Why this test exists
# --------------------
# <2–5 line narrative: bug, root cause, fix PR, defended-against class>
#
# Sister test: atilcan65/AtilCalculator scripts/tests/dNNN-<slug>.sh
#
# Exit code: 0 = all pass, 1 = at least one fail.
# Run standalone: bash scripts/tests/dNNN-<slug>.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors (TTY-aware)
if [[ -t 1 ]]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; B=$'\033[1m'; D=$'\033[0m'
else
  G=""; R=""; B=$'\033[0m'; D=""
fi

PASS=0; FAIL=0
pass() { printf "  ${G}✓ PASS${D} — %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  ${R}✗ FAIL${D} — %s\n" "$1"; [ -n "${2:-}" ] && printf "    ${R}%s\n" "$2"; FAIL=$((FAIL+1)); }
section() { printf "\n${B}==== %s ====${D}\n" "$1"; }

# T1: <property>
section "T1: <property>"
if <assertion>; then pass "<msg>"; else fail "<msg>" "<expected>"; fi

# ... T2..Tn ...

printf "\n${B}==== SUMMARY ====${D}\n  ${G}PASS${D}: %d\n  ${R}FAIL${D}: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
```

### Existing d-tests in this template

| File | Issue/PR | Defended against |
|---|---|---|
| `d015-dev-idle-prevention.sh` | Issue #119 (dev-idle prevention Katman 1+2) | Silent developer idle while queue non-empty |
| `d024-agent-wake.sh` | ADR-0024 / RCA-19 | Stale-verdict watchdog schema |
| `d025-cmd-set-argjson-contract.sh` | Issue #267 (P0 crash-loop) | JSON-quote command args in `cmd_set` |
| `d027-state-recovery.sh` | Issue #113 | State-file corruption recovery |
| `d028-no-standby.sh` | Issue #238 (P0 self-standby doctrine) | 4 forbidden standby modes |
| `d029-no-standby-watcher-text.sh` | Issue #238 | Watcher-text variant of d028 |
| `d031-claim-next-ready.sh` | ADR-0038 §Layer 2 / Issue #272 | Auto-claim correctness |
| `d032-rca-19-status-transition-wake.sh` | ADR-0036 / Issue #233 | Status-transition wake fix |
| `d033-4-soul-coverage.sh` | ADR-0038 §Layer 3 | 4 soul files have §Auto-Claim Protocol section |
| `dreg-post-restart-label-guard.sh` | Issue #261 | Post-restart label guard |

### Reference

- [ADR-0046](../docs/decisions/ADR-0046-d-test-convention.md) — full convention spec
- AtilCalculator `scripts/tests/` (d006–d033) — pattern origin
