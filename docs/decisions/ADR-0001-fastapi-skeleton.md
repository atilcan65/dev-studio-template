# ADR-0001: FastAPI service skeleton — Python pin, package manager, run command, layout

- **Status**: Accepted
- **Date**: 2026-06-10
- **Deciders**: @architect, @atilcan65 (human owner)
- **Supersedes**: —
- **Related**: docs/designs/STORY-001-design.md, STORY-002, STORY-003, STORY-004

## Context

STORY-001 is the **trunk** of Sprint 1: a FastAPI service with `/healthz` that must be runnable from a clean clone in ≤5 minutes (`AC5`). Four downstream artefacts inherit its choices:

- **STORY-002** (pytest infra) must run tests in the same env STORY-001 stands up.
- **STORY-003** (GitHub Actions CI) must install deps the same way and pin the same Python version.
- **STORY-004** (`/hello/{name}`) lives inside the same `app/` package and is tested by the same runner.
- The README tone inherits from "Atil-in-2-weeks" — onboarding is read at 9am on demo day, not at leisure.

Each of the following would take >1 day of refactor work to reverse, so per the architect's operating principle they are ADR-worthy:

| Choice | Why it is load-bearing |
|---|---|
| Python version pin | CI matrix, dev `requires-python`, Docker base image, security EOL clock |
| Package manager | Lockfile, cache strategy in CI, onboarding one-liner, dev-loop latency |
| Run/test command convention | All four stories converge on it; changing it re-derives every AC |
| Project layout (`app/` vs `src/`) | Import paths, test discovery, packaging boundary |

Without a single source of truth, every downstream story re-litigates these decisions and the demo clock burns.

## Decision

We will:

1. **Pin Python 3.12** in `pyproject.toml` (`requires-python = ">=3.12,<3.13"`) and in CI (single pin — no matrix for Sprint 1).
2. **Use `uv`** as the sole package and environment manager. No `poetry`, no `pip + venv` workflow. Dependencies declared in `pyproject.toml` under `[project]` and `[project.optional-dependencies] dev`; lockfile is `uv.lock`.
3. **Expose Makefile targets** `make run` and `make test` as the **canonical** run/test commands. `make` invokes `uv run` under the hood; developers should rarely need to type `uv run` directly.
4. **Lay the package as a flat `app/`** with `app/__init__.py` and `app/main.py` exporting the FastAPI instance as `app`. Import path: `app.main:app`. Test path: `tests/` (populated by STORY-002).
5. **`/healthz` is a synchronous handler** returning `200 OK` with body `{"status":"ok"}` and `Content-Type: application/json`. No DB, no external dependency, no async I/O.

## Rationale

### Python 3.12

- **Stability**: released Oct 2023, EOL Oct 2028 — a 2-year-and-change horizon for a Sprint 1 service.
- **Ergonomics**: improved error messages (`SyntaxError`/`NameError`/`AttributeError` show probable intent), `type` statement, `f-string` upgrades.
- **Performance**: per-project benchmarks show ~5% interpreter speedup over 3.11.
- **3.11 is the alternative** (EOL Oct 2027, broader ecosystem coverage) — but 3.12's stability window is the better risk/reward for a 2-week-out demo.
- **3.13 is rejected**: released Oct 2024; some FastAPI/Pydantic/pytest-starlash combinations are still working out the kinks. Not worth the risk for Sprint 1.

### `uv`

- **Speed**: ~10× faster cold installs than `poetry` or `pip + venv`. `uv sync` is the cold path; `uv run` is the warm path — both sub-second on a hello-world tree.
- **Single binary**: no `pipx`, no `pyenv`, no manual venv activation. `uv run pytest` is a hermetic command.
- **Drop-in pip-compatible**: any developer who knows `pip install -e ".[dev]"` can read `uv pip install -e ".[dev]"` with zero learning curve.
- **Adoption signal**: maintainers of FastAPI, Pydantic, and Ruff publicly endorsed `uv` for new projects in 2024-2025.
- **`poetry` is the alternative** — better-known, but slower, and its lockfile format adds friction when CI just needs `pip install -e .[dev]`.
- **`pip + venv` is rejected**: requires activation dance, no lockfile, and onboarding docs end up longer than the README itself.

### Makefile

- **Universally available**: present on every Linux box, present on macOS by default, present on Windows via WSL or Git-Bash.
- **Discoverable**: `make` and `make help` (if we add a `help:` target later) are universal.
- **One command, one role**: `make run` for the service, `make test` for the suite, `make install` for first-time setup. Matches the story's "one command" acceptance criterion verbatim.
- **`task` is rejected**: nicer syntax, but requires a separate binary install. Adds a step to onboarding for no Sprint 1 value.
- **`uv run` alone is rejected**: works, but the actual incantation (`uv run uvicorn app.main:app --reload --port 8000`) is long enough that newcomers will paste it from the README every time — exactly the "out-of-band tribal knowledge" AC5 forbids.

### Flat `app/` layout

- Matches the mockup in STORY-001 (`uvicorn app.main:app`).
- For a one-route service, `src/` layout is over-engineering.
- If the package later needs to be published or split, `src/atilprojects/` is the documented migration path (the only mechanical change is updating the import path in `pyproject.toml`).

### Sync `/healthz`

- FastAPI handles sync and async handlers transparently for a no-I/O endpoint — the throughput difference is unmeasurable at hello-world scale.
- Sync keeps the code readable (`def` not `async def`) and makes it harder for a future contributor to accidentally add an `await` on a non-awaited object.
- YAGNI: introduce `async` only when the route gains real I/O (DB, Redis, HTTP call).

## Consequences

### Positive

- **Cross-story alignment is locked**: `make test` in STORY-002, `make test` in the STORY-003 mockup, and the developer workflow all line up without re-derivation.
- **CI story (STORY-003) is mostly mechanical**: `actions/setup-python` with `python-version: "3.12"`, `cache: uv`, `uv sync`, `make test`. No package-manager surprise.
- **Demo-day ergonomics**: `make run` → uvicorn ready → `curl /healthz` → 200. Three commands, all named, all documented.
- **Onboarding cost is bounded**: README needs only a "what is uv" blurb and the standard FastAPI quickstart.

### Negative / Tradeoffs

- **`uv` is younger than `poetry`**: smaller mindshare. Mitigated by clear README, one-line install (`pip install uv` or `curl -LsSf https://astral.sh/uv/install.sh | sh`).
- **Makefile is old-school**: contributors who only know Python may find it quaint. The alternative (`task`, `tox`, `nox`) all add deps. Make is the lowest-dependency choice.
- **Python 3.12 is a moving pin**: in 6 months we may want 3.13 or 3.14. The pin is reversible (edit `pyproject.toml` + `actions/setup-python`), but `requires-python` and CI must move together — note this in the Sprint 2 retro.
- **Windows-native contributors**: `make` is not on Windows by default. Sprint 1's contributor base is @atilcan65 on Linux; document WSL/Git-Bash in the README; defer native-Windows ergonomics to a Sprint 2 story if needed.

### Follow-up tickets to file

- **ADR-0002**: GitHub Actions action pin policy + cache strategy (queued — needed before STORY-003 implementation).
- **Sprint 2 backlog**: Dockerise with `uv sync` in the Dockerfile; native Windows run command; structured logging; `make help` target.
- **Sprint 2 backlog**: `/healthz` deep check (DB ping) — when the first real dependency lands.

## Alignment gate (24h)

Per the architect's Sprint 1 sizing concerns, this ADR establishes a **24-hour alignment window** during which downstream stories (STORY-002, STORY-003) must converge on:

- `python-version: "3.12"` in `actions/setup-python`
- `uv sync` (or `uv pip install -e ".[dev]"`) as the install step
- `make test` as the test command
- `app/main.py` as the import path

If any of those is not respected in the corresponding PR, the architect blocks the PR with a "🟡 Suggestion" comment linking back to this ADR.
