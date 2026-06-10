# STORY-002: One-command local test suite (pytest)

## User Story
As a **founder two weeks out from a demo (Atil-in-2-weeks)**,
I want **a test suite I can run with a single command that exits 0 on green and non-zero on real failures**,
So that **I trust my pre-push self-check the night before the demo, and don't re-derive the test command every time.**

## Why now
STORY-001 stands the service up; STORY-002 makes it *trustable* before it
reaches CI. Without it, every "I ran the tests locally" claim in a PR
review is unverified — and on demo day, an unverified green is the same
as red. This is also the single piece of plumbing Maya (SRE) will
inherit next sprint, so getting the shape right *now* saves a re-do
later. Tagged for @tester because the test file layout, fixture
strategy, and naming conventions are tester-owned per the file
ownership matrix.

> Persona note (2026-06-10): see STORY-001 — primary persona is now
> Atil-in-2-weeks. AC are unchanged.

## Acceptance Criteria

- **AC1** — GIVEN a clean clone
  WHEN the developer runs the documented test command (e.g. `make test`
  or `uv run pytest`)
  THEN pytest collects and runs the suite, prints a one-line summary
  (`X passed in Y.Ys`), and exits with status code **0**.
- **AC2** — GIVEN a deliberately broken test (e.g. assertion
  `assert False`)
  WHEN the developer runs the same command
  THEN pytest exits with status code **non-zero**, the failing test name
  is shown, and a diff is included.
- **AC3** — GIVEN the test suite
  WHEN the developer runs the command with no arguments
  THEN at least one test for `/healthz` exists, asserts the 200 response,
  and at least one test for STORY-001's "unknown path returns 404" AC.
- **AC4** — GIVEN the suite
  WHEN the developer runs the command repeatedly in a clean checkout
  THEN the suite is **deterministic** — no flaky pass/fail across 5
  consecutive runs (no timing, no network, no random seeds).
- **AC5** — GIVEN the suite
  WHEN the developer inspects the repo
  THEN `tests/` exists, has at least one `__init__.py` (or pytest
  discovery-equivalent), and a `conftest.py` if any shared fixture is
  needed.

## Out of scope
- Coverage gates, coverage reports, mutation testing — Sprint 1 establishes
  *trust in the signal*, not the *completeness of the signal*. We can add
  a coverage threshold in Sprint 2 once the suite has a real shape.
- Property-based / fuzz testing — overkill for hello-world.
- Parallelism flags (`-n auto`) — not needed at this suite size; add when
  the suite takes > 30s.
- Performance / load tests — separate concern, separate story.

## Open questions
- [ ] Sync vs async test client for FastAPI? → owner: @tester
- [ ] HTTP-level test (real uvicorn on a port) vs `TestClient` (in-process)?
  Trade-off: real-port tests catch more wiring bugs but are flakier. →
      owner: @tester
- [ ] Do we want a `pytest.ini` / `pyproject.toml [tool.pytest.ini_options]`
  section, and if so, with which default flags? → owner: @tester

## Mockups / references

```
$ make test
============================= test session starts ==============================
platform linux -- Python 3.12.3, pytest-8.x.x
collected 3 items

tests/test_healthz.py ..                                                    [ 66%]
tests/test_routing.py .                                                     [100%]

============================== 3 passed in 0.42s ===============================
```

## Dependencies
- Upstream: STORY-001 (the service must exist to be tested).
- Downstream: STORY-003 (CI workflow runs this same command).

## Metrics of success
- Leading: `make test` round-trip on a clean template copy ≤ 10 seconds
  (whole point of "one command" is sub-10s feedback).
- Lagging: zero "the test passed locally but failed in CI" reports in
  Sprint 1's PRs.
