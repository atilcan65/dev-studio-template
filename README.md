# atilprojects

Multi-agent development studio powered by Claude Code with GitHub Scrum workflow.

## Architecture

- **5 Claude Code agents** (Orchestrator, PM, Architect, Developer, Tester)
- **GitHub Projects v2** as the Scrum board
- **systemd timer** for health checks (30 min cadence)
- **Telegram webhook** for cross-agent notifications

See `.claude/CLAUDE.md` for the full project context, file-ownership matrix, and process conventions.

## Repository Structure

```
.
├── .claude/                 # Agent definitions, project memory (human-only)
│   ├── agents/              # Subagent soul files
│   ├── commands/            # Slash commands
│   └── CLAUDE.md            # Project-wide context
├── .github/                 # Issue/PR templates, CI workflows (human-only)
│   ├── ISSUE_TEMPLATE/
│   └── workflows/
├── app/                     # FastAPI service (Sprint 1 STORY-001)
│   ├── __init__.py
│   └── main.py              # FastAPI app + GET /healthz
├── tests/                   # pytest suite (tester-owned, populated by STORY-002)
├── docs/                    # Product, backlog, designs, decisions, sprints
│   ├── backlog/sprint-1/    # Sprint 1 user stories
│   ├── designs/             # Per-story design docs
│   ├── decisions/           # Architecture Decision Records (ADRs)
│   └── sprints/             # Sprint plans and standups
├── scripts/                 # notify.sh, dev-studio-start.sh, health-check
├── systemd/                 # systemd service & timer units
├── pyproject.toml           # PEP 621, Python 3.12, uv-managed
├── Makefile                 # install / run / test / lint / format
└── .python-version          # 3.12 (consumed by pyenv / uv python pin)
```

## Getting started

Target: a clean machine → `200 OK` on `GET /healthz` in **≤ 5 minutes** (STORY-001 AC5).

### Prerequisites

- **Python 3.12** — pre-installed on most Linux distros, or `uv python install 3.12`.
- **uv** — the package and environment manager. Install once:
  ```bash
  pip install uv
  # or
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ```
- **make** — pre-installed on Linux and macOS. On Windows, use WSL or Git-Bash.

### Run the service

```bash
# 1. install runtime + dev deps into the project venv
make install

# 2. boot the service in the foreground (Ctrl-C to stop)
make run

# 3. in another terminal, probe the liveness endpoint
curl -i http://127.0.0.1:8000/healthz
#   HTTP/1.1 200 OK
#   content-type: application/json
#   {"status":"ok"}
```

### Run the tests

```bash
make test     # uv run pytest
make lint     # ruff check
make format   # auto-format with ruff
```

`make run` uses `uvicorn app.main:app --host 127.0.0.1 --port 8000` — bind is
explicit `127.0.0.1` so the service is **not** reachable from the network.
Do not change the bind to `0.0.0.0` without a separate design pass (see
`docs/decisions/ADR-0001-fastapi-skeleton.md` §Security & privacy).

## Sprint 1 status

Sprint 1 (2026-06-10 → 2026-06-24) is the **hello-world FastAPI** sprint.
See `docs/sprints/sprint-1/plan.md` for the committed stories, sizing, and
critical-path diagram. STORY-001 (this skeleton) is the trunk; STORY-002
(`make test` suite), STORY-003 (GitHub Actions CI), and STORY-004
(`GET /hello/{name}`) build on it.

## License

Private — internal use only.
