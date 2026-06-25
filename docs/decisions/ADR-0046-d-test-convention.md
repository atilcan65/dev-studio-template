# ADR-0046 — d-numbered regression test convention

**Status:** Proposed
**Date:** 2026-06-23
**Supersedes:** —
**Related:** ADR-0002 (autonomy loop), ADR-0025 (bound standby), ADR-0026 (queue-empty wake), `docs/decisions/INDEX.md` §Conventions, `scripts/README.md`, Issue #198 (template port), AtilCalculator `scripts/tests/` (d006–d033 family)

---

## Context

Over five sprints AtilCalculator accumulated 30+ standalone regression scripts
under `scripts/tests/` named `dNNN-<slug>.sh` (zero-padded 3-digit `NNN`,
kebab-case slug). The convention was **never formally adopted** — each
d-test was authored ad-hoc when a bug was fixed or a doctrine PR landed.
Template repo already has 10 d-tests (d015, d024, d025, d027–d029, d031–d033,
dreg) ported from AtilCalculator without an explicit convention doc.

The pattern works well in practice:

- **Each file = one bug class** (file name → issue/PR cross-reference).
- **Self-contained**: bash + grep + awk only, no pytest/pytest plugin.
- **Cross-repo traceability**: template d-tests have a "Sister test:
  atilcan65/AtilCalculator `scripts/tests/dNNN-...sh`" header comment so
  reviewers can compare behavior across repos.
- **Visible in `ls scripts/tests/`**: `d006 d007 d011 d012 d013 ...` reads
  as a bug-history index.

This ADR formalizes the convention so future contributors (human + AI agents)
follow one rule when authoring a regression script. Without it the pattern
drifts: a new contributor might write `test_foo.sh`, `regression-42.sh`, or
`d123-foo_test.sh` — three failure modes observed in PR review.

## Decision

**Adopt the d-numbered regression test convention as the canonical pattern
for `scripts/tests/` in this template.**

### File naming

```
scripts/tests/dNNN-<short-kebab-slug>.sh
```

- `NNN` — 3-digit zero-padded monotonic integer. Gaps allowed (skipped
  numbers reserved for unrelated ideas; do not re-use).
- `<short-kebab-slug>` — kebab-case, ≤ 40 chars, no underscores, lowercase.
  Prefer the bug-class noun (`no-standby`, `rca-19-status-transition-wake`)
  over a date or PR number.

### File header (mandatory, top 5 lines)

```bash
#!/usr/bin/env bash
# dNNN-<slug>.sh — regression test for Issue #N | PR #N
#
# Why this test exists
# --------------------
# <2–5 line narrative: bug, root cause, fix PR, defended-against class>
#
# Sister test: atilcan65/AtilCalculator scripts/tests/dNNN-<slug>.sh   # if cross-repo
#
# Test cases (per ADR-NNNN §dNNN spec, N TCs):
#   T1: <property checked>
#   T2: <property checked>
#   ...
#
# Exit code: 0 = all pass, 1 = at least one fail.
#
# Run standalone: bash scripts/tests/dNNN-<slug>.sh
```

### Body skeleton (mandatory)

```bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# <fixture-path or helper-script path>

# Colors (TTY-aware)
if [[ -t 1 ]]; then G=...; R=...; B=...; D=""; else ...; fi

PASS=0; FAIL=0
pass() { ... PASS=$((PASS+1)); }
fail() { ... FAIL=$((FAIL+1)); }
section() { printf "\n==== %s ====\n" "$1"; }

# T1: <property>
section "T1: <property>"
if <assertion>; then pass "<msg>"; else fail "<msg>" "<expected>"; fi

# ... T2..Tn ...

printf "\n==== SUMMARY ====\n  PASS: %d\n  FAIL: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
```

### Authoring rules

1. **One file per bug class / doctrine fix.** Never bundle two regressions.
2. **Number = next available.** Grep `ls scripts/tests/d[0-9]* | sort -V`,
   pick the next free integer. Do not backfill gaps unless deliberately
   representing the original chronology.
3. **First line `set -uo pipefail`** (NOT `-e` — assertions must run even
   after a `grep` returns 1).
4. **Standalone runnable.** Every test exits 0/1 with no env vars, no
   fixtures in `/tmp`, no network. `bash scripts/tests/dNNN-<slug>.sh`
   must work from a fresh clone.
5. **Cross-repo sister-test comment** when porting an AtilCalculator d-test.
   Use the same `NNN` number as the AtilCalculator original for
   traceability (already followed for d015, d024, d025, d027–d029, d031–d033,
   dreg).
6. **TDD red-first**: author the failing assertion FIRST, observe the
   failure, THEN write the fix. Document the pre-change failure in the
   header narrative.

### When NOT to write a d-test

- **Unit-level business logic** → use `pytest` (see ADR-0017 §Tech stack).
  d-tests are for **script-level / integration / shell-doctrine** regressions.
- **One-off CLI scripts** → no test needed (low reuse, low regression risk).
- **Behavior that's already covered by an existing d-test** → add a T-cases
  to that file instead of a new file.

## Rationale

Three alternatives considered:

| Alternative | Effect | Verdict |
|---|---|---|
| **(a)** Adopt pytest for all regression scripts | Unified with engine unit tests | ❌ Rejected — pytest does not cover shell-script behavior (bash quoting, exit codes, gh CLI JSON). Would require a shim layer for every script regression. |
| **(b)** Leave convention informal | Zero process overhead | ❌ Rejected — observed drift in PR review (3 different naming proposals on the same PR). The convention is cheap to write down and saves review cycles. |
| **(c)** (chosen) Formalize the d-test pattern that already exists | Codify the working pattern; no new tooling | ✅ Adopted — 30+ d-tests prove the pattern. Codification prevents drift without imposing a new framework. |

The "boring tech wins" heuristic applies: a 3-line naming rule + a
header template + a body skeleton is the entire convention. No new
tooling, no new dependency, no migration cost (existing d-tests already
follow the rule).

## Consequences

### Positive

- **Reviewable-by-filename**: PR titles like `fix(scripts): port dNNN regression (Issue #N)` map 1:1 to a file. No context switch.
- **Cross-repo sister-test ref** enables diff-based review when AtilCalculator fixes a bug and template ports it (already followed for 10 d-tests).
- **Standalone runnable** means contributors can `bash scripts/tests/d015-dev-idle-prevention.sh` from any cwd, no `pytest` setup, no venv.
- **Bug-class ledger**: `ls scripts/tests/d[0-9]*` reads as the team's defect history.

### Negative

- **Not a substitute for unit tests**: d-tests are coarse (one per bug class, not one per function). The engine module keeps its `pytest` suite per ADR-0017. Acceptable.
- **File count grows linearly with bug count**: not a concern at our scale (5 sprints → 30 files; projected 5 years → ~150 files). If growth becomes a problem, group by domain subdirs (`scripts/tests/wake/`, `scripts/tests/rca/`).
- **Header boilerplate is verbose**: the 5-line "Why this test exists" narrative is the largest line-count contribution. Treated as **a feature, not a bug** — the narrative is what makes the file self-documenting.

### Out of scope (this ADR)

- **Test-runner orchestrator** (run all d-tests, aggregate PASS/FAIL, CI integration) — separate ADR if/when CI integration lands.
- **Coverage metrics** (% lines, % branches) — d-tests are coarse-grained; coverage tracking belongs with `pytest`.
- **Performance regression timing** — d-tests are correctness-only.
- **Migration of existing tests not named `dNNN-*.sh`** — `e2e-pilot.sh`, `faz5-smoke.sh`, `state-schema-smoke.sh` predate the convention and stay as-is.

### Follow-up tickets

1. `@developer`: when authoring a new d-test, follow this ADR's header + body skeleton. Reference ADR-0046 in the PR body.
2. `@architect`: add `scripts/tests/dNNN-*.sh` to the §Conventions block of `docs/decisions/INDEX.md.tmpl` (link to this ADR).
3. `@tester`: when reviewing a new d-test, verify: (a) monotonic `NNN` (no reuse), (b) sister-test comment when porting, (c) standalone runnable, (d) TDD red-first narrative in header.

## Future work

- **Domain subdir grouping** if file count exceeds ~50 (`scripts/tests/wake/`, `scripts/tests/rca/`, `scripts/tests/owner-override/`).
- **CI integration** via a `scripts/run-d-tests.sh` runner that exits non-zero on any FAIL.
- **Sister-test diff helper** (`scripts/diff-sister-test.sh <NNN>`) to surface behavioral drift between AtilCalculator and template d-tests.

---

**Sister ADRs:** None — this is the **first formalization** of the d-test pattern. Previous d-tests (d006–d033 in AtilCalculator, d015/d024–d033 in template) were authored ad-hoc following the same pattern; this ADR makes the pattern explicit.

**Trigger:** Issue #198 (Sprint 2+3 template port candidates, 2026-06-23T12:16:16Z auto-claim) — PR-T9 "d-numbered regression test pattern" chosen as the highest-value port because the template already has 10 d-tests with no governing ADR.