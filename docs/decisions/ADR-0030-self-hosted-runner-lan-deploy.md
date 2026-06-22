# ADR-0030: Self-Hosted GitHub Runner for Private LAN Deploy

- **Status**: Proposed
- **Date**: 2026-06-19
- **Deciders**: @architect, @developer, @human
- **Supersedes**: ADR-0027 §Decision.1 (LAN-deploy case only; §Decision.2+3+5 unchanged)
- **Related**: ADR-0027, ADR-0010, Issue #138 (P0 incident), Issue #130 (DEPLOY-001), Issue #139 (architect decision), PR #136 (DEPLOY-001 impl)

## Context

ADR-0027 §Decision.1 chose **public GH Actions runner on push to main** for the deploy pipeline. On 2026-06-19T20:12:47Z, the first auto-deploy attempt (workflow run #27846373740) **failed at the SSH dial** because the public runner cannot reach 192.168.1.199:22 (private LAN). This is a **fundamental design flaw**, not a configuration issue — GH Actions public runners intentionally cannot reach private IPs.

The chosen Option A is broken for a single-host LAN deployment. Sprint 3 P0 (DoD §4: ≥3 successful auto-deploys) cannot start until this is resolved.

This ADR supersedes ADR-0027 §Decision.1 (LAN-deploy case only) and ratifies the architectural pivot.

## Decision

**Use a self-hosted GitHub Actions runner installed on the prod host, registered against this repo, running as a dedicated `gh-actions-runner` user with no sudo and no SSH login.**

The workflow YAML changes from:
```yaml
runs-on: ubuntu-latest
```
to:
```yaml
runs-on: self-hosted
```

No other architectural changes to ADR-0027 §Decision.2+3+5 (secrets, smoke test + rollback, idempotency).

## Rationale

### Why self-hosted runner (vs. the alternatives considered)

| Option | Effort | New infra | Security | Latency | Reversibility | Verdict |
|---|---|---|---|---|---|---|
| **D. Self-hosted GH runner on prod** | ~30 min owner | None (existing prod host) | Good (dedicated user, no public exposure) | <1 min | High (uninstall runner) | ✅ **CHOSEN** |
| E. Cloudflare Tunnel (cloudflared) | ~15 min owner | cloudflared service | Excellent (zero-trust) | <1 min | Medium (tunnel config persists) | ❌ External service dependency |
| B. systemd timer polling main | ~20 min dev | systemd timer + polling daemon | Good | up to 5 min | High | ❌ Latency too high; would have been better than A but D is better |
| Manual deploy (defer to Sprint 4) | 0 min | None | N/A | N/A | N/A | ❌ Doesn't solve the prod-liveness gap |
| ngrok-style reverse tunnel | ~10 min | ngrok auth token | Poor (token in repo secret) | <1 min | Low | ❌ Not production-grade |

**Why D over E**: Cloudflare adds external service dependency (third-party uptime, account, tunnel auth, billing). Self-hosted runner is a small GH-native addition to the existing prod host. **Less surface, not more.**

**Why D over B (the option originally rejected in ADR-0027 §Alternatives)**: ADR-0027 §Decision.1 rejected B for "extra VM infra, latency" — but B doesn't require extra VM (systemd timer runs on prod host), and 5-min polling latency is acceptable for the deploy-automation use case. However, **D has lower latency** (<1 min vs. up to 5 min) and is the GH-native pattern. D is preferred. **B is the fallback if D fails for some reason** (e.g., GH runner service is broken on the host).

### Why a new ADR (not ADR-0027 amendment)

ADR-0027's §Decision.1 chose a wrong option. Amending an accepted ADR to reverse its core decision creates ambiguity (amend-1 supersedes §Decision.1 vs. amends it). A new ADR that explicitly states "supersedes ADR-0027 §Decision.1 for the single-host LAN-deploy case" is cleaner and preserves the audit trail.

§Decision.2 (SSH key + auth), §Decision.3 (smoke test + auto-rollback), §Decision.5 (idempotency), and §Threat model (SHA pinning, no sudo, single-user SSH) are **unchanged**.

## Consequences

### Positive

- ✅ Sprint 3 P0 unblocked
- ✅ Workflow YAML update: `runs-on: ubuntu-latest` → `runs-on: self-hosted`
- ✅ Lower latency than Option B (systemd timer polling)
- ✅ No external service dependency (unlike Cloudflare/Tailscale)
- ✅ Matches existing prod host pattern (systemd user-service per ADR-0010)
- ✅ Idempotent converge + smoke test + auto-rollback (ADR-0027 §3+5) still applies

### Negative (mitigated by threat model below)

- ⚠️ New threat surface: self-hosted runner has shell on prod
- ⚠️ Runner maintenance: auto-update via GH runner service, but adds one more systemd unit
- ⚠️ Runner token rotation: quarterly (matches ADR-0027 §4 secret rotation cadence)

### Threat model

| Risk | Severity | Mitigation |
|---|---|---|
| **Malicious PR runs arbitrary code on prod** | **P0** | Use `pull_request` (read-only, public runner) for PR validation; `push` (write, self-hosted) for trusted merges. **Only `push to main` triggers self-hosted runner.** `pull_request_target` is **forbidden** for self-hosted. |
| Runner process has shell on prod host | P1 | Dedicated user `gh-actions-runner`, no sudo, no SSH login, no write access outside `~/projects/AtilCalculator`. systemd hardening (`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=true`). |
| Runner registration token leaked | P1 | Rotate token quarterly (matches secret-rotation cadence per ADR-0027 §4). Store token only in `/home/gh-actions-runner/.runner` on prod host, not in any GH secret. |
| Compromise of self-hosted runner → prod compromise | P0 | `git reset --hard origin/main` is idempotent (ADR-0027 §Decision.5); worst case = bad code deployed, smoke test catches, auto-rollback to HEAD@{1}. Plus smoke test asserts `git_sha == GITHUB_SHA` (DEPLOY-003 contract). |
| Cross-PR contamination (PR A's deploy racing PR B's) | P2 | `concurrency: { group: production-deploy, cancel-in-progress: false }` (already in PR #136 workflow). Deploys serialize. |
| Self-hosted runner compromised → SSH key compromised | P1 | SSH key (`DEPLOY_SSH_KEY`) is on the runner host filesystem; rotate quarterly + after any runner compromise. The runner user has no SSH login (only the deploy SSH key, used by the runner to SSH to the same host). |
| GH Actions runner software has a CVE | P2 | GH runner auto-updates by default; we will pin a minimum version in `docs/ops/self-hosted-runner-setup.md` and document the upgrade procedure. |

### Implementation steps (operator runbook)

1. **Owner creates dedicated user** on prod host: `sudo useradd -m -s /bin/bash gh-actions-runner` (no sudo, no SSH login)
2. **Owner downloads GH Actions runner** as `gh-actions-runner` user: see [GitHub runner setup docs](https://docs.github.com/en/actions/hosting-your-own-runners/adding-self-hosted-runners)
3. **Owner registers runner** against this repo (`github.com/atilcan65/AtilCalculator`) with label `self-hosted`. Token expires after 1 hour; rotate at registration time.
4. **Owner installs runner as systemd service** (per [docs](https://docs.github.com/en/actions/hosting-your-own-runners/configuring-the-self-hosted-runner-application-as-a-system-service))
5. **Owner hardens runner**:
   - `sudo systemctl edit actions.runner.*.service` → add `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=true`
   - Disable SSH login: `sudo usermod -s /usr/sbin/nologin gh-actions-runner` (after runner is set up; runner service runs as this user, no shell needed)
6. **Owner adds `docs/ops/self-hosted-runner-setup.md`** with step-by-step operator procedure
7. **Developer updates workflow YAML** in PR #136 follow-up: `runs-on: ubuntu-latest` → `runs-on: self-hosted` + RCA-3 fix (`script_path` → `script`)
8. **Owner approves workflow file merge** per CLAUDE.md §File ownership matrix (`.github/workflows/` is human-only)
9. **Test with one real merge** to validate the pipeline end-to-end
10. **Sprint 3 DoD §4** updated to "≥3 successful self-hosted-runner auto-deploys"

### Sprint 3 impact

- DEPLOY-001 impl DONE (PR #136, but workflow YAML needs follow-up for `runs-on` + RCA-3)
- DEPLOY-001 deployment BLOCKED until this ADR is Accepted + owner sets up runner + workflow YAML updated
- Other Sprint 3 work (RETRO-003, TEMPLATE-PORT, #119, #48) is **not blocked** and can proceed in parallel
- Sprint 3 P0 DoD §4 + §5 updated (see "Implementation steps" §10)

### Tech-debt

- **TD-015** (filed 2026-06-19): ADR-0027 §Decision.1 architectural mistake. Severity: M (corrected within Sprint 3; not a recurring pattern). Payoff trigger: Sprint 3 retro.

## Alternatives considered (rejected)

- **Option A (public GH runner)** — REJECTED. Broken for LAN-deploy. Documented in Issue #138.
- **Option E (Cloudflare Tunnel)** — REJECTED. External service dependency.
- **Option B (systemd timer polling)** — REJECTED for primary path (5-min latency), but **RETAINED as fallback** if self-hosted runner fails.
- **Option F (manual deploy, defer to Sprint 4)** — REJECTED. Doesn't solve the prod-liveness gap.
- **Option G (ngrok-style reverse tunnel)** — REJECTED. Not production-grade.

## Open questions

- [ ] Should the self-hosted runner have a separate SSH key (not `DEPLOY_SSH_KEY`)? — **Defer to operator runbook author** (`docs/ops/self-hosted-runner-setup.md`); current plan is to reuse `DEPLOY_SSH_KEY` (the runner is on the same host as the prod app, so it SSHes to itself).
- [ ] Should we run the runner in a Docker container for isolation? — **Defer**. Adds complexity. systemd hardening is sufficient for our threat model.
- [ ] Quarterly runner-token rotation procedure — to be added to `docs/ops/self-hosted-runner-setup.md`.

## References

- Issue #138 — P0 incident (first auto-deploy failed)
- Issue #139 — Architect decision request
- Issue #130 — DEPLOY-001 story
- PR #136 — DEPLOY-001 implementation (workflow + runner script)
- PR #134 — DEPLOY-003 /healthz endpoint (merged 2026-06-19T19:30:01Z)
- ADR-0027 — Deploy automation (parent ADR, partially superseded)
- ADR-0010 — Per-project systemd watchers (systemd precedent)
- [GitHub: Adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/adding-self-hosted-runners)
- [GitHub: Configuring self-hosted runner as systemd service](https://docs.github.com/en/actions/hosting-your-own-runners/configuring-the-self-hosted-runner-application-as-a-system-service)
