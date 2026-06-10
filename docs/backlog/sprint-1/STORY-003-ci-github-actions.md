# STORY-003: GitHub Actions CI workflow on every PR

## User Story
As a **founder two weeks out from a demo (Atil-in-2-weeks), and a future SRE (Maya)**,
I want **the test suite to run automatically on every PR and post a pass/fail check back to the PR**,
So that **the merge button reflects a real signal — and on demo day there are no green-on-paper surprises.**

## Why now
STORY-002 makes the test signal *locally available*; STORY-003 makes it
*socially enforced* — nobody has to remember to run `make test` before
pushing, and the reviewer sees a green check that is the *same* green
check CI saw. This is the difference between a script and a workflow.
Tagged `type:chore` because it is infrastructure, not a product feature,
and assigned to @developer because CI YAML is platform plumbing (not
test logic). Note: per CLAUDE.md, agents **propose** changes to
`.github/workflows/` via PR; the human owner must approve before merge.

> Persona note (2026-06-10): see STORY-001 — primary persona is now
> Atil-in-2-weeks. Maya remains adjacent (this story is the one piece
> that exists for *Maya's future self* as much as for Atil's demo).

## Acceptance Criteria

- **AC1** — GIVEN a PR is opened (or pushed to) `main`
  WHEN GitHub Actions runs the new workflow
  THEN the workflow installs dependencies and runs the **exact same
  command** as STORY-002's `make test`, and posts a check on the PR.
- **AC2** — GIVEN a PR with a failing test
  WHEN CI runs
  THEN the PR check is **red**, the workflow log shows the failing test
  name and diff, and merging is blocked (branch protection).
- **AC3** — GIVEN a PR with all green tests
  WHEN CI runs
  THEN the PR check is **green**, the workflow completes in **≤ 3
  minutes** (target, not gate), and the PR is mergeable from CI's side
  (subject to other protections).
- **AC4** — GIVEN the workflow file
  WHEN the developer inspects it
  THEN it triggers on `pull_request` and `push` to `main`, uses a pinned
  action SHA or version, and has at least one cached dependency layer
  (e.g. `actions/setup-python` with cache) so re-runs are fast.
- **AC5** — GIVEN the workflow
  WHEN a developer reads the YAML
  THEN the file has a short header comment explaining what it does and
  which STORY it implements.

## Out of scope
- Deploy steps, staging/prod environments — there is no deploy target in
  Sprint 1; that earns its own story.
- Matrix builds across Python versions — premature; one pinned version is
  fine for v1.
- Lint / type-check / security-scan steps — each is a separate concern and
  a separate story. Don't piggyback.
- Auto-merge, label automation, CODEOWNERS — out of scope for v1.

## Open questions
- [ ] Python version in CI matrix: single pin (3.12) or matrix (3.11, 3.12,
      3.13)? → owner: @developer (recommend: single pin for Sprint 1)
- [ ] Runner: `ubuntu-latest` is the default assumption. Confirm? →
      owner: @developer
- [ ] Should the workflow upload a test-results artefact on failure?
      Trade-off: reviewability vs storage noise. → owner: @developer

## Mockups / references

```yaml
# .github/workflows/ci.yml
# Implements STORY-003 — runs STORY-002's test suite on every PR and push to main.
name: CI
on:
  pull_request:
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip
      - run: pip install -e ".[dev]"
      - run: make test
```

## Dependencies
- Upstream: STORY-001 (service), STORY-002 (runnable test command).
- Downstream: branch protection rule (human-owned, not in this story).

## Metrics of success
- Leading: median CI run time ≤ 3 minutes on a typical PR.
- Lagging: zero "CI passed but main is red" incidents in the 24h after
  Sprint 1 ends, and zero demo-day surprises traceable to "the tests
  weren't actually run on this branch."
