# ADR-0014: PROJECT_TOKEN repo secret for board sync workflow

**Status:** Accepted
**Date:** 2026-06-14
**Supersedes (auth section only):** ADR-0013

## Context

ADR-0013 introduced `status-label-to-board.yml`, a workflow that mirrors
`status:*` label changes onto the Projects v2 board's Status field. The
original design used the default `GITHUB_TOKEN`, on the assumption that for
user-owned projects living in repos owned by the same user, that token would
be sufficient.

That assumption was wrong. Production evidence on the first project
bootstrap (AtilCalculator, board #6, run `27506301845`):

```
GraphqlResponseError: Request failed due to following response errors:
 - Could not resolve to a ProjectV2 with the number 6.
```

The default `GITHUB_TOKEN`:

1. Does not carry the `project` scope.
2. Has no `permissions:` key in the workflow YAML that grants ProjectsV2
   access (only `repository-projects: write` exists, which controls
   Projects *classic*, not v2).
3. Therefore returns `NOT_FOUND` for any `user(...) { projectV2(...) }`
   GraphQL query, even when the project clearly exists and belongs to the
   same user as the repo.

This is a hard ceiling — no amount of workflow `permissions:` tweaking can
fix it. ProjectsV2 mutations require a PAT (or a GitHub App token) with the
`project` scope.

Because dev-studio-template is **template-grade** (every new project
re-bootstraps from scratch), this needs to be solved once, in the template,
in a way that costs the operator nothing per project.

## Decision

**Provision a repo secret named `PROJECT_TOKEN` automatically during
`dev-studio-init.sh`, holding a classic PAT with `repo` + `project` scopes,
and reference it from the board-sync workflow as
`secrets.PROJECT_TOKEN`.**

### PAT specification

- Type: **classic** PAT (not fine-grained).
- Scopes: `repo` + `project`.
- Reuse: the **same PAT** is reused across every new project — that's why
  classic. Fine-grained PATs are repo-scoped, which would force a new PAT
  per project and break template-grade ergonomics.
- Lifetime: user's choice. Recommend 90 days with calendar reminder, or
  "no expiration" with personal risk acceptance.

### Init flow

`dev-studio-init.sh` runs `ensure_project_token()` immediately after
`resolve_values` and before `render_all`:

1. If `PROJECT_TOKEN` env var is set → use it (CI / scripted runs).
2. Otherwise prompt interactively with `read -s` (no echo).
3. Validate format (`ghp_*` classic or `github_pat_*` fine-grained).
4. Write to repo secret via `gh secret set PROJECT_TOKEN --body - --repo
   $OWNER/$REPO` (stdin so the token never appears in `ps`).
5. Hard fail on empty / malformed / write failure — the rest of init is
   meaningless without it.

### Workflow reference

`.github/workflows/status-label-to-board.yml.tmpl`:

```yaml
with:
  github-token: ${{ secrets.PROJECT_TOKEN || secrets.GITHUB_TOKEN }}
```

The fallback to `GITHUB_TOKEN` exists **only** so the workflow file is
syntactically valid before init runs. In practice the GraphQL call will
fail loudly with `NOT_FOUND` if `PROJECT_TOKEN` is missing, surfacing the
misconfiguration in Actions logs rather than silently no-op'ing.

## Alternatives considered

### A. GitHub App
Cleanest long-term answer (per-installation tokens, fine-grained perms),
but setup is heavy: app creation, private key management, installation
per repo. Overkill for a personal dev-studio-template. **Rejected** for
now; revisit if multi-user / org adoption appears.

### B. Manual per-repo secret
Have the user add `PROJECT_TOKEN` via the GitHub UI for every new project.
Violates the "ben otomatik olmasını istiyorum" user contract and breaks
template-grade ergonomics. **Rejected.**

### C. Fine-grained PATs
Per-repo PATs with `Projects: read & write`. More secure in principle,
but the operator must produce a new PAT per project, defeating the
template-grade goal. **Rejected** for default; left as a possible
forward-compat path (the format validator accepts `github_pat_*`).

### D. Leave it broken / manual board sync
"Just drag the card on the board." Defeats the entire purpose of
ADR-0013. **Rejected.**

## Consequences

### Positive

- Board sync **actually works** on first bootstrap, no GitHub UI steps.
- One PAT, one prompt (or one `export`), template-grade across all
  future projects.
- Token never echoed (read -s), never in `ps` args (stdin to gh).
- Idempotent: re-running init overwrites the secret cleanly.

### Negative / risks

- **Blast radius**: classic PAT with `repo` scope is broad. Mitigations:
  - Recommend 90-day expiration.
  - Document the trade-off in CLAUDE.md.
  - Possible future migration to GitHub App (ADR-XXXX).
- **Single point of failure**: if the user revokes the PAT, every project's
  board sync stops until they re-run init (or `gh secret set` manually).
  Acceptable — surfaces immediately in Actions logs.

### Operational guidance

- **First time:** generate at <https://github.com/settings/tokens>
  (classic), scopes `repo` + `project`, copy the `ghp_...` value.
- **Re-use:** `export PROJECT_TOKEN=ghp_...` in your shell rc, or paste
  at the init prompt.
- **Rotation:** generate a new PAT, `export` it, re-run init in each
  active project to refresh the secret.

## Related ADRs

- **ADR-0012** — Required label set (the `status:*` labels this workflow
  consumes).
- **ADR-0013** — Status label → board sync workflow (this ADR fixes its
  auth model).

## References

- Failing run: `https://github.com/atilcan65/AtilCalculator/actions/runs/27506301845`
- Error: `Could not resolve to a ProjectV2 with the number 6`
- GitHub docs: <https://docs.github.com/en/actions/security-guides/automatic-token-authentication>
