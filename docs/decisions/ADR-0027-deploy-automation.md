# ADR-0027 — Automatic Deploy Pipeline (GitHub Action on main merge → SSH pull+restart)

**Status:** Proposed
**Date:** 2026-06-19
**Deciders:** @architect, @atilcan65 (workflow-file ownership per CLAUDE.md §File ownership matrix)
**Related:** ADR-0010 (per-project systemd watchers — runtime infra precedent), ADR-0014 (PROJECT_TOKEN repo-secret precedent), ADR-0017 (tech stack), ADR-0022 (SQLite persistence — affects deploy payload)

---

## Context

Sprint 2 merged 5 of 6 P1 stories to `main` (PR #88 STORY-007, #111 STORY-008, #112 STORY-009, #118 STORY-010, #117 STORY-011). The production site, however, **does not reflect Sprint 2 code** — the owner (per Issue #127 body) reports Sprint 1 deploys were manual (SSH `git pull` + service restart on prod host `192.168.1.199`, per ADR-0010).

**Owner directive (Issue #127, 2026-06-19T17:12Z):** automatic deploy on main merge. PM scoping answer (Issue #127 cmt, 17:21Z): Sprint 3 first story, three sub-stories (DEPLOY-001 trigger, DEPLOY-002 secrets, DEPLOY-003 smoke test + rollback), 8 SP total.

This ADR is the **architectural design decision** for DEPLOY-001 + DEPLOY-002 + DEPLOY-003's shape. Implementation follows in Sprint 3 once the ADR is Accepted.

### Constraints (from prior doctrine + CLAUDE.md)

1. **Workflow files (`.github/workflows/`) are human-only** per CLAUDE.md §File ownership matrix. The architect **proposes** the workflow file content via PR; the owner merges with explicit approval.
2. **Repo secrets** are the canonical pattern for credentials (ADR-0014 PROJECT_TOKEN precedent). SSH key MUST live as a repo secret, not in workflow YAML.
3. **Prod host** is `192.168.1.199` (per ADR-0010). Service is a systemd user-service per ADR-0017 runtime infra clause.
4. **Engine ↔ UI separation** (ADR-0017): deploy must pull both `src/atilcalc/` and `src/atilcalc/web/` (engine + static UI). The frontend has no build step (ADR-0018).
5. **Idempotency**: deploys may retry on transient failure; the post-merge state on prod MUST converge to the post-merge state on `main` regardless of how many deploys fire.
6. **Observability**: every deploy MUST emit a structured log line (deploy start, deploy end, smoke-test result). Owner reads `/var/log/dev-studio/AtilCalculator/deploy.log` on prod.

### Threat model (per Hard Rules §Security)

- **Credential theft**: SSH key in repo secret (`DEPLOY_SSH_KEY`). Read by Action only on `main` push event (branch filter). Never echoed to logs.
- **Supply chain**: Action pinned by SHA, not tag (per GH Actions security guidance). Tag-pinned Actions can be retroactively modified by the Action publisher; SHA-pinned Actions cannot.
- **Rollback attack**: a malicious PR merged to main could push a regression. Mitigated by (a) PR review chain (CLAUDE.md §Process — tester signoff + human approval), (b) post-deploy smoke test (DEPLOY-003) that auto-rolls back on failure.
- **Prod host compromise**: SSH key is scoped to a single user on `192.168.1.199` (no sudo). Service restart uses `systemctl --user` (ADR-0010 precedent), not root.

## Decision

Adopt a **GitHub Action on `push to main`** that **SSH-pulls** the latest `main` HEAD onto the prod host and **restarts the systemd user-service**. Three sub-decisions:

### 1. Trigger topology — GitHub Action vs alternatives

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **A. GitHub Action on `push to main`** | Native GH integration, no extra infra, branch-filterable, repo-secret compatible | Requires owner to merge workflow PR (CLAUDE.md §human-only) | ✅ **Chosen** |
| B. systemd timer polling `main` every N min | No GH Action needed; matches ADR-0010 watcher pattern | Latency (worst case N min), no atomicity on deploy, harder to audit | Rejected — adds VM-side infra complexity without payoff |
| C. Webhook receiver on prod host | Real-time, no polling | New attack surface (public webhook endpoint), requires TLS cert + auth | Rejected — security cost > latency benefit |

**Rationale:** GitHub Actions is the platform-native CI/CD for the repo. The human-only workflow-file constraint is acceptable because it routes the deploy-pipeline definition through the same review chain as code. Latency is bounded by GH Action runner availability (typically <2 min from merge to deploy start).

### 2. Auth — SSH key in repo secret + `appleboy/ssh-action` (or equivalent)

- **Repo secret**: `DEPLOY_SSH_KEY` (private key, ed25519, no passphrase; rotated quarterly per §Secret rotation below).
- **Repo secret**: `DEPLOY_HOST` (default `192.168.1.199` per ADR-0010; overridable for staging).
- **Repo secret**: `DEPLOY_USER` (default `atilcan`; systemd `--user` requires the same UID as the service).
- **Action step**: `appleboy/ssh-action@v1` (or `ssh-action` maintained equivalent), pinned by SHA. The Action:
  1. SSHes to `$DEPLOY_HOST` as `$DEPLOY_USER`
  2. Runs `bash -lc "cd ~/projects/AtilCalculator && git fetch origin && git reset --hard origin/main"`
  3. Runs `bash -lc "systemctl --user restart atilcalc-web.service"` (per ADR-0010 §systemd user-service)
  4. Returns the exit code; non-zero fails the Action run

### 3. Smoke test + rollback — DEPLOY-003 (companion design)

- **Smoke test endpoint**: `GET /healthz` (returns `{"status": "ok", "git_sha": "<sha>"}` if engine imported successfully, 503 otherwise). New endpoint, owned by DEPLOY-003.
- **Post-deploy**: Action runs `curl -fsS http://192.168.1.199:PORT/healthz` (PORT per ADR-0010 systemd unit). Expects `200` and a `git_sha` matching the just-deployed SHA.
- **Rollback on failure**: Action runs `bash -lc "cd ~/projects/AtilCalculator && git reset --hard HEAD@{1}"` (the previous SHA), restarts the service, retries health check. If second health check fails, Action exits non-zero and pages owner via `scripts/notify.sh -l human`.

### 4. Secret rotation strategy

- **Cadence**: quarterly (every 90 days). Owner rotates manually; no automation in scope for this ADR.
- **Rotation procedure**:
  1. Owner generates new ed25519 keypair on prod host.
  2. Owner adds new public key to `~/.ssh/authorized_keys` (alongside old key, for grace period).
  3. Owner updates `DEPLOY_SSH_KEY` repo secret with new private key.
  4. Owner tests a deploy (any merge to main).
  5. After 7-day grace period, owner removes old public key from `~/.ssh/authorized_keys`.
- **Audit**: rotation events logged to `docs/sprints/sprint-N/rotation-log.md` (new file pattern, owner-maintained).

### 5. Idempotency

- The Action's `git reset --hard origin/main` is **idempotent by design**: every run converges prod to current `main` HEAD regardless of prior state.
- A no-op deploy (Action fires but `main` SHA hasn't changed since last deploy) still runs the smoke test. This is intentional — it validates that the systemd service is alive after a host reboot.

### 6. Observability

- **Action logs**: GH Actions UI shows step-by-step output (git fetch output, systemctl status, curl response). Owner-readable at `https://github.com/atilcan65/AtilCalculator/actions`.
- **Prod-side log**: systemd journal (`journalctl --user -u atilcalc-web.service`) captures service-restart events. Mirror to `/var/log/dev-studio/AtilCalculator/deploy.log` via existing `journalctl` follow pattern.
- **Audit log**: every successful deploy writes a marker file `~/.deploy-marker` with the SHA + timestamp. Readable by `scripts/deploy-status.sh` (proposed Sprint 3).

## Rationale

The chosen pattern (GH Action + SSH pull + systemd restart + smoke test) is the **boring, well-trodden GitOps-lite path** for self-hosted single-VM deploys. It avoids:
- **GH Actions self-hosted runner** (added infra to maintain; rejected — more moving parts than value).
- **Kubernetes / Docker orchestration** (rejected — Sprint 1 chose systemd user-service per ADR-0010; orchestration would be over-engineering for a single-VM deployment).
- **Push-based deploys from CI to prod** (rejected — pull-based from prod to GitHub is more secure: prod holds the key, GitHub does not push).

The human-only workflow-file constraint is preserved by routing the workflow YAML through the same PR review chain as code (owner approval required to merge).

## Consequences

### Positive

- **Latency**: <5 min from `main` merge to prod live (GH Action trigger + SSH + restart + smoke test).
- **Reversibility**: smoke-test failure auto-rolls back; manual rollback is `git reset --hard HEAD@{1} + systemctl --user restart`.
- **Auditability**: GH Actions log + prod journal + deploy-marker file give 3 independent records of every deploy.
- **Test coverage**: DEPLOY-003 smoke test is a new endpoint, contract-testable in Sprint 2 (pre-Sprint-3) to de-risk the design.

### Negative / Tradeoffs

- **Workflow-file ownership**: requires owner approval for every change to `.github/workflows/deploy.yml`. Same as code review — acceptable.
- **Secret rotation is manual**: quarterly key rotation is owner toil. Not automated in this ADR; revisit if rotation becomes a hotspot.
- **No blue/green deploy**: a regression on `main` is live for ~3 min between merge and smoke-test failure. Mitigation: PR review chain (existing).
- **No multi-host**: single prod host only. Multi-host would need different topology (rejected as YAGNI).

### Follow-up tickets (Sprint 3 backlog)

- **DEPLOY-001** (3 SP): Implement `/.github/workflows/deploy.yml` + `scripts/deploy-runner.sh` per this ADR. Owner approves workflow file.
- **DEPLOY-002** (2 SP): Wire `DEPLOY_SSH_KEY` + `DEPLOY_HOST` + `DEPLOY_USER` repo secrets. Owner generates ed25519 keypair on prod host.
- **DEPLOY-003** (3 SP): Implement `GET /healthz` endpoint with `git_sha` introspection. Add `tests/api/test_healthz.py` contract. Wire post-deploy smoke test + rollback in workflow YAML.
- **DEPLOY-004** (1 SP, optional): `scripts/deploy-status.sh` for owner-side audit queries (last deploy SHA, time, status). Defers to Sprint 3 grooming decision.

### Architectural observations (informational)

- **Per CLAUDE.md §Things agents must NEVER do**: "Modify `.github/workflows/`, secrets, branch protection without explicit human approval." Architect writes the design (this ADR); developer writes the impl in Sprint 3 with the standard PR review chain; **owner approves the workflow file merge**. No agent touches secrets or branch protection directly.
- **PR review chain still applies**: DEPLOY-001/002/003 implementation PRs go through architect + tester + human signoff (CLAUDE.md §Definition of Done).

## Sprint 3 supplement (TD-019, post-RCA-7 deploy failure)

**Status:** Supplement added 2026-06-20 via PR #158 (TD-019 docs PR). Tracked in `docs/tech-debt.md` row TD-019. Sister to TD-016 + TD-018 in the "blind-spot family" (see `docs/tech-debt.md` §"Blind-spot family").

This ADR was **the pattern doc**. The actual prod instance details diverged from the pattern in 4 places, surfaced by Issue #152 RCA-7 (post-PR #151 deploy failure). The supplement records the **instance corrections** so future agent reviews don't re-derive the wrong path from the pattern.

### Instance corrections (4 layers, from Issue #152 RCA-7)

1. **Actual prod hostname**: `atiltestweb` (not `192.168.1.199` as ADR-0027 §Context §3 + §Decision.2 + §Threat model originally stated). `192.168.1.199` was a placeholder used in early Sprint 1/2 docs; the actual host is `atiltestweb`. Repo var `DEPLOY_HOST` should be set to `atiltestweb` (was defaulted to `192.168.1.199` in workflow YAML per PR #146).

2. **Actual deploy path**: `/home/atilcan/atilcalc` (not `~/projects/AtilCalculator` as scripts/deploy-runner.sh line 32 default assumed). The `gh-actions-runner` user checks out to its own workspace (`/home/gh-actions-runner/actions-runner/_work/AtilCalculator/AtilCalculator/` = `$GITHUB_WORKSPACE`), not a `~/projects/` path. PR #151 already fixed the script default to `$GITHUB_WORKSPACE`; this supplement records the canonical for documentation.

3. **Canonical restart mechanism**: **nohup+setsid**, NOT `systemctl --user restart atilcalc-web.service`. The systemd unit `atilcalc-web.service` was **never installed on this host** (`find /etc/systemd /home/atilcan/.config/systemd -name 'atilcalc*'` returns empty). The unit was specified in ADR-0010 + ADR-0027 as the canonical pattern, but the prod instance uses nohup+setsid instead. PR #153 (DEPLOY-001 v5) implements the nohup+setsid path in `scripts/deploy-runner.sh` as the long-term fix. **Recommendation**: keep ADR-0010 + ADR-0027 systemd pattern as a **documented option** (alternative), but the operational reality is nohup+setsid. ADR-0010 supplement (Sprint 4 backlog) will document this in the watcher ADR; this ADR documents it in the deploy ADR.

4. **Canonical Python module path**: `atilcalc.api.main:app` (NOT `atilcalc.web.app:app` as Issue #152 orchestrator 04:47Z guidance hallucinated). Verified by 12 references in repo: `scripts/run-server.sh` (1) + 11 test files in `tests/`. `atilcalc.web` package exists but contains only an empty `__init__.py` (vanilla JS Web Components, no Python `app` object). PR #153 will use the canonical path.

### Doctrine amendment (TD-019: canonical-entry cross-check)

Before issuing prod-host commands, workflow YAML snippets, or design doc recommendations, the agent MUST grep the canonical entry script and confirm:
- (a) **module path** — `scripts/run-server.sh` (or equivalent `Makefile` / `pyproject.toml [project.scripts]`)
- (b) **restart mechanism** — `pkill` + `nohup setsid uvicorn ...` pattern (NOT `systemctl --user restart`)
- (c) **preflight steps** — `uv pip install -p .venv -e .` (deps), pre-flight unit-existence check (warn, don't fail)
- (d) **post-deploy verification** — `curl /healthz` returning `git_sha` matching `$GITHUB_SHA`

This doctrine is captured in `docs/tech-debt.md` row TD-019, the "Blind-spot family" consolidation, and (per RETRO-003 plan) will be amended into the architect + orchestrator soul files (`.claude/agents/architect.md`, `.claude/agents/orchestrator.md`).

### Optional CI lint check (Sprint 4 backlog)

`scripts/tests/d019-canonical-entry-cross-check.sh` — bash script that greps `scripts/deploy-runner.sh` against `scripts/run-server.sh` for module-path consistency. Out of scope for this PR (purely docs); owner may add as Sprint 4 backlog item.

## Alternatives considered (full table)

| Option | Trigger | Auth | Smoke test | Verdict |
|---|---|---|---|---|
| **A. GH Action + SSH pull (chosen)** | `push to main` | SSH key in secret | `GET /healthz` post-deploy | ✅ |
| B. systemd timer polling main | host-side cron | N/A (no remote auth) | host-side healthz | ❌ extra VM infra, latency |
| C. Webhook receiver on prod | GH webhook | webhook secret | host-side healthz | ❌ attack surface |
| D. Self-hosted GH runner on prod | `push to main` | runner auth | host-side healthz | ❌ runner maintenance burden |
| E. rsync + GH release artifact | `release published` | SSH key | host-side healthz | ❌ orthogonal model; no benefit |

---

**Open questions** (to resolve in Sprint 3 grooming):
- [ ] Is `appleboy/ssh-action` acceptable, or does owner prefer direct `ssh` command in Action (fewer dependencies)?
- [ ] Healthz endpoint: should it return engine-eval result (e.g., `2+2`) or just import-check? (recommendation: just import-check + git_sha, keep it cheap)
- [ ] Multi-branch support: should `staging` branch auto-deploy to a separate host, or only `main` deploys? (recommendation: only `main` for now)

— @architect, 2026-06-19