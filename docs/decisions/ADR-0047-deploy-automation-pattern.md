# ADR-0047 — Deploy automation pattern (template-port of AtilCalculator ADR-0027 + ADR-0030)

**Status:** Proposed
**Date:** 2026-06-25
**Supersedes:** —
**Related:** ADR-0046 (d-test convention — sister), AtilCalculator ADR-0027 (auto-deploy pattern source), AtilCalculator ADR-0030 (self-hosted runner source), AtilCalculator `scripts/deploy-runner.sh` v9.1 (live implementation), Issue #375 (architect design verdict), Issue #198 (parent template-port story)

---

## Context

Issue #198 (TPL-PORT-481) tracks Sprint 2+3 lessons to be ported from
AtilCalculator to dev-studio-template. Sub-PRs PR-T8 (`scripts/deploy-runner.sh` +
`.github/workflows/deploy.yml`) and PR-T10 (ADR-0027 + ADR-0030 generalization)
are coupled — same source, two artifacts (impl + docs). AtilCalculator's
`scripts/deploy-runner.sh` is now 562 LOC (v9.1, after RCA-7/9/11/12/14 hardening)
and `.github/workflows/deploy.yml` is 124 LOC — both are deeply
AtilCalculator-specific:

- `atilcalc-web.service` systemd unit name (hardcoded)
- `atilcalc.api.main:app` Python module path (hardcoded)
- `ATC_PORT` (AtilCalculator prefix), `/healthz` path (hardcoded)
- `atiltestweb` prod hostname (warn-only check, hardcoded)
- RCA-7/9/11/12/14 incident refs in script header (AtilCalc-specific)
- Notify page target `scripts/notify.sh -l human` (already template-port-ready)

Template users need a working deploy-automation pattern without re-deriving it
from the 562-LOC AtilCalculator source. Three abstraction options were
considered in Issue #375:

| Option | Description | Lens analysis |
|---|---|---|
| **A — Light-touch** | Parameterize 4 env vars (SERVICE_NAME, MODULE_PATH, DEPLOY_PORT, HEALTHZ_PATH) + 1 optional (PROD_HOSTNAME). Sister to PR-T9 ADR-0046. | ✅ Decisive win (9-lens) |
| B — Medium | Same as A + rename `deploy-runner.sh` → `.sh.tmpl` + add template-flavored header section | ❌ Adds reviewer load without addressing critical gaps |
| C — Heavy | Fork into template-only ADR + minimal 50-line orchestrator that delegates to user scripts | ❌ Fails lens (d) silent-skip on missing DEPLOY_PREFLIGHT_SCRIPT + lens (g) arbitrary-code risk via user-provided preflight |

**Architect verdict on Issue #375, 2026-06-25 (comment 4801011342): Option A
agreed.** Decisive lenses: (d) silent-skip — Option A's fail-loud env-var
contract prevents the RCA-7-4 silent WARN pattern; (g) security — Option A
parameterizes PROD_HOSTNAME rather than dropping it; (b) runtime preconditions —
4 env vars beat Option C's 6.

This ADR formalizes the pattern as it lands in the template repo. AtilCalculator
ADRs 0027 + 0030 are NOT superseded (they ARE the working instance). Sister-ADR
pattern: template ADR-0047 = abstract/parameterized pattern; AtilCalculator
ADR-0027 + ADR-0030 = concrete working instance.

## Decision

**Adopt the deploy-automation pattern as the canonical pattern for
`scripts/deploy-runner.sh` + `.github/workflows/deploy.yml.tmpl` in this
template.** Pattern is generic, env-driven, project-agnostic.

### Env-var contract (4 required + 1 optional)

| Name | Required | Type | Default | Example | Purpose |
|---|---|---|---|---|---|
| `SERVICE_NAME` | **YES** | string | — | `myapp-web` | Service identifier for logs + notify (no systemd unit dependency per §Decision.2) |
| `MODULE_PATH` | **YES** | string | — | `myapp.api.main:app` | Python module:app object for uvicorn |
| `DEPLOY_PORT` | **YES** | integer | — | `8000` | TCP port to bind + smoke-test against |
| `HEALTHZ_PATH` | **YES** | string | — | `/healthz` | Healthcheck endpoint path (must return JSON with `git_sha` field) |
| `PROD_HOSTNAME` | optional | string | (skip check) | `myapp-prod-01` | Warn-only hostname validation (lens g safety net, opt-in) |
| `GITHUB_SHA` | **YES** (caller) | 40-char hex | — | `abc1234...` | The SHA to converge prod to + assert in smoke test |
| `REPO_DIR` | optional | path | `$GITHUB_WORKSPACE` or `$(pwd)` | `/home/deploy/myapp` | Repo checkout location |
| `DEPLOY_HOST` | optional | hostname | `127.0.0.1` | `127.0.0.1` | Smoke-test curl target (loopback when runner is on prod host) |
| `DEPLOY_BIND_HOST` | optional | hostname | `0.0.0.0` | `0.0.0.0` | uvicorn bind host (LAN-reachable vs loopback) |
| `HEALTHZ_TIMEOUT_SEC` | optional | integer | `5` | `10` | Per-attempt curl timeout |
| `SMOKE_ATTEMPTS` | optional | integer | `5` | `10` | Number of smoke-test retries before rollback |
| `SMOKE_RETRY_DELAY_SEC` | optional | integer | `2` | `5` | Delay between smoke-test retries |

**Lens d fail-loud contract**: missing required env var → script `exit 3` with
stderr `ERROR: <NAME> required (e.g., <example>)`. No silent WARN/SKIP. This is
the RCA-7-4 anti-pattern defense — verified by `d046-deploy-runner-env-validation.sh`
T1-T4.

### Restart pattern: nohup+setsid (NOT systemctl --user)

**Chosen restart mechanism**: `pkill <existing PID on port> && nohup setsid
<uvicorn> <MODULE_PATH> --host <DEPLOY_BIND_HOST> --port <DEPLOY_PORT>`.

Rationale: template users may not have systemd user-service configured. The
nohup+setsid pattern is **universal** — works on any host with bash + uvicorn.
AtilCalculator v9 uses `systemctl --user start <service>` (per ADR-0010) for
better lifecycle management on their prod host, but that's an instance-specific
refinement, not the pattern. The template pattern is the boring-tech-wins
choice (per ADR-0017 §3).

**Trade-off acknowledged**: nohup-spawned uvicorn is terminated by GH Actions
"Cleanup orphan processes" step at job end IF the runner is on the same host as
prod (self-hosted runner pattern from ADR-0030). AtilCalculator's solution was
v9's systemd user-service + `loginctl enable-linger` to survive logout. Template
users running a self-hosted runner on the prod host MUST adopt the same
systemd pattern (or use a service supervisor like supervisord/runit). Documented
in `scripts/README.md` §deploy-runner.

### Cross-user port-ownership checks (RCA-12 defense-in-depth)

Two checks preserve the AtilCalculator RCA-12 hardening:

1. **Pre-restart**: `ss -tlnp "sport = :$DEPLOY_PORT"` (or `lsof -ti :$DEPLOY_PORT` fallback)
   → extract PID + uid → if uid mismatch, fail-fast. Cross-user service stop not
   possible without sudo.
2. **Post-restart**: after 2s bind-settle, `ss -tlnp "sport = :$DEPLOY_PORT"`
   → verify the port-bound process started RECENTLY (etimes ≤ 60s). Catches the
   "pre-existing uvicorn survived pkill" silent-skip bug.

Pre-check should catch all cross-user scenarios; post-check is the backstop if
the pre-check tool (`ss`/`lsof`) is missing or port is in transient state.

### Idempotency + smoke test + auto-rollback (sister to AtilCalculator ADR-0027 §3+5)

- **Step 1**: `git fetch origin && git reset --hard origin/main` — idempotent converge
- **Step 2** (preflight, optional): `uv venv .venv` (if missing) + `uv pip install -p .venv -e .`
  — FAIL-or-CREATE pattern (RCA-9 fix); only runs if `.venv` exists or
  `pyproject.toml [project.optional-dependencies]` is detected. Templates using
  system Python or containerized runtime skip this step.
- **Step 3** (restart): per §Decision.2 (nohup+setsid + RCA-12 checks)
- **Step 4** (smoke test): `curl $HEALTHZ_URL` → parse JSON → extract `git_sha` →
  assert `actual_sha == GITHUB_SHA`. Retry `SMOKE_ATTEMPTS` times with
  `SMOKE_RETRY_DELAY_SEC` between attempts.
- **Step 5** (rollback on smoke-test failure): `git reset --hard HEAD@{1}` + restart
- **Step 6** (retry smoke test once): if it passes, `exit 1` (deploy failed but
  rollback succeeded, owner should be notified)
- **Step 7** (double-failure): page owner via `scripts/notify.sh -l human`; `exit 2`

### Workflow file: `.github/workflows/deploy.yml.tmpl`

Template workflow uses **SHA-pinned Action references** per ADR-0027 §Threat
model + ADR-0043 lens (h). Template users rename `.yml.tmpl` → `.yml` at install
time (per template's existing `.md.tmpl` install pattern). Workflow secrets
(`DEPLOY_SSH_KEY`, `DEPLOY_HOST`, `DEPLOY_USER`) are passed via env to the
deploy-runner.sh invocation.

The template workflow has 5 env vars at the workflow level (passed to the
deploy step):

```yaml
env:
  SERVICE_NAME: ${{ vars.SERVICE_NAME }}
  MODULE_PATH: ${{ vars.MODULE_PATH }}
  DEPLOY_PORT: ${{ vars.DEPLOY_PORT }}
  HEALTHZ_PATH: ${{ vars.HEALTHZ_PATH }}
  PROD_HOSTNAME: ${{ vars.PROD_HOSTNAME }}
```

Template users set these via repo Settings → Secrets and variables → Actions →
Variables (or hardcode in the workflow YAML after renaming).

## Rationale

Three alternatives considered:

| Alternative | Effect | Verdict |
|---|---|---|
| **(a)** Adopt the AtilCalculator deploy-runner.sh verbatim (562 LOC, AtilCalc-specific) | Zero abstraction work | ❌ Rejected — template users would need to grep-and-replace 5+ AtilCalc-specific strings; error-prone |
| **(b)** Fork into template-only ADR + 50-line orchestrator that delegates to user scripts | Maximum flexibility | ❌ Rejected per Issue #375 verdict — fails lens (d) silent-skip on missing DEPLOY_PREFLIGHT_SCRIPT, plus lens (g) arbitrary-code risk |
| **(c)** (chosen) Parameterize 4 env vars + 1 optional + nohup+setsid restart + sister-ADR pattern | Boring-tech-wins, sister to PR-T9 ADR-0046 | ✅ Adopted — 200 LOC (vs 562), env-driven, single-source-of-truth env-var table |

The "boring tech wins" heuristic applies (per ADR-0017 §3): 4 env vars + 1
optional + a generic restart pattern is the entire abstraction. No new tooling,
no new dependency, no migration cost (template users start from the abstract
pattern, not from AtilCalc's 562-LOC instance).

## Consequences

### Positive

- **Template-portable**: 4 env vars cover 99% of self-hosted single-VM deploy use cases.
- **Sister-ADR pattern**: AtilCalculator ADR-0027 + ADR-0030 stay (working instance); template ADR-0047 is the abstract pattern. Bidirectional cross-link via §Related.
- **Boring tech**: nohup+setsid works on any host with bash + uvicorn. No systemd dependency.
- **Defensive hardening**: RCA-12 cross-user port checks preserved (lens d fail-loud + lens g security).
- **Test coverage**: d046 (env validation, 9 TCs) + d047 (smoke test, 7 TCs) per ADR-0046 d-test convention. Total 16 TCs verify the pattern contract.
- **Production-tested sister**: the abstract pattern is derived from AtilCalculator's RCA-hardened v9.1 implementation (562 LOC). Template users inherit the same hardening without re-deriving it.

### Negative

- **nohup+setsid vs systemd trade-off**: template users running a self-hosted runner on the prod host need to add a service supervisor (systemd, supervisord, runit) to keep the service alive across runner cleanup. AtilCalculator v9 chose systemd user-service + `loginctl enable-linger`. Documented in `scripts/README.md` §deploy-runner.
- **Generic `.tmpl` install pattern**: users must rename `.github/workflows/deploy.yml.tmpl` → `.github/workflows/deploy.yml` at install time. Same pattern as `docs/decisions/INDEX.md.tmpl` (existing convention).
- **No multi-host orchestration**: single prod host only. Multi-host would need a different topology (rejected as YAGNI per ADR-0027 §Negative).
- **Manual env-var setup**: template users set 4 env vars in repo Settings → Variables before first deploy. No defaults in the workflow YAML (would be opaque to audit).

### Out of scope (this ADR)

- **Workflow file ownership**: `.github/workflows/` is human-only per CLAUDE.md §File ownership matrix. Template repo's workflow file ships as `.yml.tmpl` (template-marked) so the install-time rename is a project-init choice, not a workflow-file edit by an agent.
- **Multi-branch support**: only `main` branch deploys. Staging branch deploy to separate host deferred (per AtilCalculator ADR-0027 §Open questions).
- **Blue/green deploy**: single prod host, no traffic shifting. Regression on `main` is live for ~3 min between merge and smoke-test failure. Mitigation: PR review chain + smoke-test auto-rollback.
- **Healthz endpoint contract**: template users implement their own `/healthz` returning `{"status": "ok", "git_sha": "<sha>"}`. Per ADR-0027 §Decision.3 + AtilCalculator DEPLOY-003 (`GET /healthz` endpoint, PR #134 merged).

### Follow-up tickets

1. `@developer`: when implementing a new project's deploy, follow this ADR's env-var table. Reference ADR-0047 in the PR body that renames `.github/workflows/deploy.yml.tmpl` → `deploy.yml`.
2. `@architect`: keep template ADR-0047 in sync with AtilCalculator ADR-0027 + ADR-0030 amendments (bidirectional sister-ADR pattern). Quarterly cross-repo audit.
3. `@tester`: when reviewing a project's deploy PR, verify: (a) 4 env vars set in repo Variables, (b) `HEALTHZ_PATH` returns JSON with `git_sha` field, (c) d046 + d047 pass against the project-specific `scripts/deploy-runner.sh` (or equivalent), (d) PROD_HOSTNAME set if multi-host.
4. `@human`: review + approve the `.github/workflows/deploy.yml` rename PR (workflow file = human-only per file ownership matrix).

## Future work

- **Domain subdir grouping** for project-specific deploy scripts (`scripts/deploy/project-foo.sh`, `scripts/deploy/project-bar.sh`) — defer until 5+ projects use the pattern.
- **Sister-test diff helper** (`scripts/diff-sister-adr.sh ADR-0047 ADR-0027`) to surface behavioral drift between template and AtilCalculator deploy patterns.
- **Cross-repo workflow sync** (per ADR-0040): if AtilCalculator changes `deploy.yml`, auto-port to template `deploy.yml.tmpl` via cross-repo-close pattern.
- **d048-deploy-runner-rollback.sh** — dedicated regression for the rollback + retry-smoke-test path (currently covered by d047 T5 + smoke).

---

**Sister ADRs (bidirectional cross-link):**

- **AtilCalculator ADR-0027** — concrete working instance of this pattern (auto-deploy on push to main). AtilCalculator `scripts/deploy-runner.sh` v9.1 (562 LOC) implements the pattern with AtilCalc-specific service name + module path + port + healthz path + RCA-7/9/11/12/14 hardening refs.
- **AtilCalculator ADR-0030** — concrete self-hosted runner pattern (supersedes AtilCalculator ADR-0027 §Decision.1 for the LAN-deploy case). Sister to this ADR's nohup+setsid restart decision.
- **Template ADR-0046** — d-test convention (sister to this ADR; both follow the same env-driven, testable, sister-ADR pattern).

**Trigger:** Issue #198 (Sprint 2+3 template port candidates, 2026-06-23T12:16:16Z auto-claim) — PR-T8 + PR-T10 coupling (impl + ADR generalization) chosen as highest-value deploy-related port because the pattern is production-tested in AtilCalculator v9.1 but no template-port version existed.

**Architect verdict on Issue #375:** 2026-06-25T15:24:02Z (comment 4801011342), Option A agreed.