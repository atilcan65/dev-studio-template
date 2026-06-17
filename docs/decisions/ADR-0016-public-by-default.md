# ADR-0016 — Public-by-default for projects bootstrapped from this template

**Status:** Accepted
**Date:** 2026-06-17
**Supersedes:** —
**Related:** ADR-0014 (PROJECT_TOKEN secret + canary workflow)

---

## Context

`dev-studio-init.sh` runs an end-to-end canary workflow on the freshly
created repo to validate that `PROJECT_TOKEN` reaches the runner intact
(ADR-0014 §3.5). This canary uses GitHub Actions, which on **private**
repos is **paid** beyond a free monthly minute quota.

Observed failure during AtilCalculator bootstrap (2026-06-17, run
`27670464719`):

```
Status: Failure
Total duration: 5s
Annotations:
  Verify PROJECT_TOKEN reaches runner intact
    The job was not started because recent account payments have
    failed or your spending limit needs to be increased. Please check
    the 'Billing & plans' section in your settings.
```

The canary job never started — no PAT problem, no scope problem, no
network problem. GitHub refused to schedule the runner because the
account hit its private-repo Actions quota. The init script's
`run_secret_canary()` correctly aborted with `conclusion=failure`, but
its error message blamed the token ("secret stored in the repo is
corrupted, revoked, or lacks scope") — which is the dominant cause but
not this one. The user spent time investigating PAT scopes that were
fine.

This is a **template-grade** problem. The template promises that
`new-project.sh` brings a working multi-agent dev studio up in one
command. If every project requires the operator to first audit their
GitHub Actions spending limit, the one-command promise breaks.

The `dev-studio-launcher` (`new-project.sh`) was hard-coded to
`gh repo create --private` since v0.1. Private was chosen as the
"safer" default in the absence of evidence either way. ADR-0014's
canary then made that default actively harmful for accounts on the
free tier.

Two additional facts are relevant:

1. **Template repo is already public.** `atilcan65/dev-studio-template`
   itself runs as PUBLIC (set during PR #30 cycle, security-scanned,
   clean — no real tokens, no IPs, no `.env` leakage). Projects
   bootstrapped from it inherit its source code structure with new
   placeholders rendered; they do not contain different sensitive
   material than the template itself.
2. **Secrets are not source.** `PROJECT_TOKEN` lives in GitHub's
   encrypted secret store, not in the repository tree. Repository
   visibility (public/private) does not expose secrets — they remain
   readable only by GitHub Actions runners and the repo admin UI.

## Decision

**The launcher's default repo visibility is `--public`. `--private` is
an explicit opt-in flag.**

### Launcher behaviour (`dev-studio-launcher` v0.3+)

- `new-project.sh <name>` → creates a **public** repo.
- `new-project.sh <name> --private` → creates a **private** repo.
  Operator accepts that the project will not run on a free Actions
  quota; canary may fail with "job not started" until billing is
  configured.
- `new-project.sh <name> --public` → explicit, same as default. Kept
  for symmetry / muscle memory.

The change is breaking-ish for anyone scripting against the v0.2
default; the README documents this and the canary's improved diagnostic
(below) directs operators to this ADR.

### Init script diagnostic improvement (this repo)

When `run_secret_canary()` sees `conclusion=failure`, the fail message
now distinguishes:

- **Token-class failure** (HTTP 401/403, validated path, observed in
  ADR-0014 §3.4 / §3.5): "secret is corrupted, revoked, or lacks
  scope" — existing message, kept verbatim.
- **Job-never-started failure** (canary completes in <10s with no
  job logs, repo is private, conclusion=failure): adds a second
  diagnostic line pointing at billing/visibility — "if the canary
  failed in seconds with no job output and this repo is private,
  Actions quota is the likely cause; see ADR-0016."

This is a hint, not a hard branch — quota detection from outside the
Actions billing API is unreliable, and false positives are cheap.
The message preserves the original token diagnostic and adds the
quota hint as a secondary line.

### What is *not* changing

- ADR-0014 (`PROJECT_TOKEN` + canary) stands as-is. The canary is
  still mandatory; we are not making it skippable by default.
- `DEV_STUDIO_SKIP_PROJECT_TOKEN=1` escape hatch is unchanged — it
  exists for CI smoke tests, not as a fix for the quota problem.
- Existing private projects are not migrated. This ADR governs new
  projects bootstrapped after the launcher v0.3 cut.

## Alternatives considered

### A. Document the spending-limit step in the README, keep `--private` default

Rejected. This puts the burden on every new project's first 30
minutes and contradicts the template-grade one-command promise. Most
free-tier accounts would hit the same wall the first time.

### B. Skip the canary on quota failure

Rejected. The canary exists precisely because the PROJECT_TOKEN
secret can be corrupted in silent ways (ADR-0014 §3.5). Skipping it
re-opens that whole failure class.

### C. Switch to GitHub App authentication

Considered, deferred (same posture as ADR-0014 §A). GitHub Apps would
remove the PAT entirely and side-step the canary's reason for
existing, but the implementation cost — App provisioning, installation
permissions UX, per-project installation step — is large enough that
ADR-0014 explicitly punted it. This ADR does not re-open that
decision; it provides a low-cost improvement that works *today*.

### D. Detect quota and fall back to public automatically

Rejected. Implicit visibility flips violate operator expectations.
A public repo created without intent could expose code the operator
considered private. The decision must be visible at `gh repo create`
time.

### E. Use repository templates' "private" via org-level Actions
quota uplift

Rejected. Out of scope for a self-hosted template; not every operator
has an organization or a budget for Actions minutes.

## Consequences

### Positive

- One-command bootstrap stays one command on free-tier accounts.
- Canary is reliable; no flaky "job not started" failures on first
  init.
- Diagnostic improvement reduces 30-minute debug sessions on the
  rare quota case to "30 seconds, see ADR-0016."

### Negative / risks

- Operators who want private projects now type `--private` explicitly.
  Documented in README + `--help`.
- Public projects are world-readable from the first commit. The
  template is already public; bootstrapped projects carry the same
  posture. Operators planning genuinely private work should pick a
  different starting point (or set `--private` and accept the
  Actions billing implication).

### Operational guidance

- **Pre-existing private projects** that hit the canary quota failure
  have three options: (a) make repo public (`gh repo edit <repo>
  --visibility public --accept-visibility-change-consequences`),
  (b) raise the spending limit at
  `https://github.com/settings/billing/spending_limit`,
  (c) re-bootstrap with launcher v0.3 (public default).
- **New launcher versions** that change the visibility default again
  in the future must amend this ADR or supersede it.

## Related ADRs

- ADR-0014 — PROJECT_TOKEN repo secret for board sync workflow (this
  ADR exists because ADR-0014's canary surfaces the quota issue).

## References

- AtilCalculator canary failure (2026-06-17, run
  `27670464719`): https://github.com/atilcan65/AtilCalculator/actions/runs/27670464719
- GitHub Actions billing for private repos:
  https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions
- Launcher: https://github.com/atilcan65/dev-studio-launcher
