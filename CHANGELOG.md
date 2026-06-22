# Changelog

All notable changes to this project are recorded here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **#39 — `§Doctrine Reminder — no self-standby` (Issue #238) replaces Issue #119
  in 5 soul templates.** Ported from AtilCalculator Issue #238 (P0 doctrine
  gap, owner-discovered 2026-06-22: agents self-standby on dependency /
  rate-limit / state-corruption / no-events despite the existing §Doctrine
  Reminder). The Issue #119 patch was 3-bullet (polling / queue / auto-ping)
  — it told agents to **do** things but did not enumerate the **forbidden
  self-justifications** that look like work pauses. The new doctrine adds an
  explicit 4-row forbidden-pause table (blocked-on-dep, rate-limit, state
  corruption, no-events) + 3-question self-check + role-specific callout
  per file. **Per-role callouts** — orchestrator: re-run proactive board
  scan / architect: draft next ADR or design doc / developer: branch +
  implement next P0/P1 issue / product-manager: open story or refresh
  backlog / tester: run next d-reg test or sign off next PR. Supersedes
  PR #35 (Katman 3) and Issue #119 §Doctrine Reminder text. `dev-idle
  prevention` / `Issue #119 §Doctrine Reminder` heading text removed from
  all 5 .tmpl files; Issue #119 retained as a Ref predecessor. Regression
  pin: `scripts/tests/d028-no-standby.sh` (4 TCs, one per forbidden mode).

### Added

- **Auto-Ping dual-channel wiring (ADR-0033, Issue #221 port to template — Issue
  #222).** Mirror of the AtilCalculator Sprint 4 P0 fix. Three new files +
  two doctrine updates:
  - `scripts/agent-wake.sh` (new, ~75 lines) — standalone CLI that injects
    a wake-up prompt into a named agent's tmux pane via `send-keys -l` +
    `Enter`. Role-to-pane index map (orchestrator=0, ..., tester=4) with
    title-based fallback. Silent no-op when tmux missing / unknown role /
    no session — callers don't need to guard. Exit 2 on missing args.
  - `scripts/notify.sh` — `-w` (wake) and `-r <role>` flags added. After
    Telegram POST, when `-w` is set, `notify.sh` invokes `agent-wake.sh`
    to inject the wake prompt into the target pane. `-w` requires `-r`;
    `-w` without `-r` → exit 2 (loud failure). Backward compat: when
    `-w` is NOT set, behavior is unchanged (Telegram only).
  - `scripts/tests/d024-agent-wake.sh` (new, ~165 lines) — 7-TC regression
    test per ADR-0033 §Test contract (T1 send-keys + Enter, T2 no-tmux,
    T3 unknown-role, T4 missing-args exit 2, T5 dual-channel wiring,
    T6 -w/-r requirement check, T7 literal-mode). Locks in both the
    `agent-wake.sh` shape AND the `notify.sh` dual-channel integration.
  - `.claude/CLAUDE.md.tmpl` — §Auto-Ping Hard-Rule updated: explains
    dual-channel doctrine (Telegram + tmux), when to use `-w` (acil
    handoff) vs. when NOT (bilgilendirme amaçlı ping).
  - `.claude/agents/developer.md.tmpl` — Auto-Ping section adds ADR-0033
    callout: acil handoff'larda `-w -r <role>` flag'i ekle.

  Reference impl: `atilcan65/AtilCalculator` commit `ecbf21a` (PR #239).
  TDD red→green in template: d024 5/7 PASS pre-port → 7/7 PASS post-port.

### Fixed

- **#61 — Watcher phantom re-delivery of `board-*` events (P1).** Orchestrator's
  `agent-watch.sh` loop was receiving the same two `label_change` events
  (`board-50-*`, `board-52-*`) repeatedly across polls, even though both source
  issues are CLOSED with `status:done` and the resolving PRs (#51, #54) are
  merged. Two interacting bugs caused the dedup chain to fail: **(A)** the
  three HWM vars (`LAST_SEEN`, `PR_MERGED_LAST_SEEN`, `PR_LABELED_LAST_SEEN`)
  were read ONCE at script start and never refreshed inside `poll_once`, so a
  long-running `--loop` watcher's local vars drifted behind the state file's
  HWM and the gh query kept returning historical events; **(B)** the
  `processed_event_ids` FIFO trim (default 50) was evicting the still-active
  phantom event IDs as newer events flooded in. The fix moves all three HWM
  reads into `poll_once` (via `init_pr_merged_hwm` and `init_pr_labeled_hwm`
  helpers) and bumps `DEFAULT_TRIM_MAX` from 50 to 200 as a backstop. The
  orchestrator's INBOX is now clean across 10+ consecutive polls. Regression
  pin: `scripts/tests/d213-phantom-board-dedup.sh` (10/10 PASS).

- **STORY-002 — `app/main.py` now registers a SIGTERM handler (TC-8 unblock).**
  `kill <pid>` (SIGTERM) on the uvicorn process used to exit with code
  `143` (= 128 + SIGTERM), which breaks container/k8s/systemd graceful
  shutdown. The handler is installed at module-import time and calls
  `os._exit(0)` (C-level `_exit(2)`), mirroring uvicorn's own SIGINT
  behaviour without raising `SystemExit` — this avoids a `CancelledError`
  traceback from the asyncio loop's pending Starlette `lifespan` task,
  satisfying STORY-001 AC4 ("no traceback on shutdown"). No-op for
  Ctrl-C development; load-bearing the moment the service ships to a
  process supervisor. See PR #24 (`test_sigterm_exits_zero`) for the
  subprocess-level regression pin and PR #25 / `tests/test_sigterm_handler.py`
  for the in-process pin.

### Changed

- **PR #35 — DEV-IDLE-K3 Katman 3: Doctrine Reminder in 5 soul templates**
  (post-merge CHANGELOG; refs AtilCalculator #119, #196, #197, ADR-0025
  retired). Each of the 5 `.claude/agents/*.md.tmpl` files
  (`orchestrator.md.tmpl`, `product-manager.md.tmpl`, `architect.md.tmpl`,
  `developer.md.tmpl`, `tester.md.tmpl`) now ships a `## Doctrine Reminder —
  dev-idle prevention (Issue #119)` section directly below its
  `## Hard Rules — DON'T` block. The reminder makes three rules
  unconditional and reflexive: **(1) polling is unconditional** — every
  session start + every action triggers `bash scripts/agent-watch.sh <role>`
  (no owner-poke dependency); **(2) queue check is reflexive** — every
  open issue with `agent:<role>` or `cc:<role>` is active work, start
  immediately; **(3) auto-ping is reflexive** — `scripts/notify.sh -l <next-role>`
  on task-completion or block, no human-relay. Forbidden phrases explicitly
  enumerated: `standby`, `holding`, `iş saatleri`, `ofis-saati`,
  `sabah bakacağım`, `yarın devam` — none are valid pause justifications.
  Valid pause gates: (a) verbatim human chat directive, (b) issue/PR-linked
  dependency block, (c) heartbeat/REPRIME SOP step. Closes the dev-idle
  doctrine gap observed in AtilCalculator 2026-06-19 wake-loop incidents;
  enforced by `scripts/tests/d015-dev-idle-prevention.sh` (regression pin,
  re-verified post-merge). Net change: 5 files × +12 lines = +60/-0
  (purely additive, no template contract breaks).

### Added

- **STORY-001 — FastAPI service skeleton with `GET /healthz`** (Sprint 1, P0).
  Standalone FastAPI service runnable from a clean clone with one command
  (`make run`); liveness probe at `/healthz` returns `200 OK` with
  `{"status": "ok"}` and `Content-Type: application/json`. Unknown paths
  return `404` (not `500`). `Ctrl-C` exits cleanly with code `0`.
  See [`docs/backlog/sprint-1/STORY-001-fastapi-skeleton-healthz.md`](docs/backlog/sprint-1/STORY-001-fastapi-skeleton-healthz.md),
  [`docs/designs/STORY-001-design.md`](docs/designs/STORY-001-design.md),
  and [`docs/decisions/ADR-0001-fastapi-skeleton.md`](docs/decisions/ADR-0001-fastapi-skeleton.md).

- **STORY-004 — `GET /hello/{name}` greeting endpoint** (Sprint 1, P1).
  Demo-facing route that returns `200 OK` with
  `{"message": "hello, {name}"}` and `Content-Type: application/json`.
  Case is preserved verbatim (no lowercasing); URL-encoded values pass
  through unchanged (e.g. `/hello/%20` → `"hello,  "`). The path segment
  is required, capped at 64 characters to bound log-spam risk; missing
  name returns `404` (FastAPI default), not `500`.
  See [`docs/backlog/sprint-1/STORY-004-hello-name-greeting-endpoint.md`](docs/backlog/sprint-1/STORY-004-hello-name-greeting-endpoint.md).

### Infrastructure

- `pyproject.toml` — PEP 621, Python `>=3.12,<3.13`, pinned runtime deps
  (`fastapi==0.115.6`, `uvicorn[standard]==0.32.1`) and dev extras
  (`pytest`, `httpx`, `ruff`). Ruff config and pytest config colocated.
- `Makefile` — canonical `install` / `run` / `test` / `lint` / `format`
  targets, all thin wrappers around `uv run` (ADR-0001).
- `.python-version` — `3.12` for `uv python pin` and `pyenv` consumers.
- `app/__init__.py` — package marker with `__version__ = "0.1.0"`.
- `app/main.py` — FastAPI instance + sync `GET /healthz` handler.
- `tests/test_healthz.py` — single skeleton smoke test (AC2 happy path).
  Full contract test suite (404, determinism, subprocess lifecycle,
  README on-ramp timing) lands in STORY-002.
- `tests/test_hello.py` — 4 contract tests for `/hello/{name}` (AC1–AC4
  of STORY-004). Happy-path + case-preservation pair satisfies AC5.
- `README.md` — Sprint 1 repo layout + 4-step "Getting started" (Install
  uv → `make install` → `make run` → `curl /healthz`).
