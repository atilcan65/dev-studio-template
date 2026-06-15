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

### Live health-check (added 2026-06-14, after first failure)

Writing the secret via `gh secret set` validates **storage only** —
GitHub accepts any bytes you hand it. The first AtilCalculator bootstrap
hit this exact gap: the secret was "written", every init log line was
green, the user submitted a Vision issue, and the board-sync workflow
failed with `HTTP 401 Bad credentials`. Root cause was an invisible
character in the env-var path that survived the `printf '%s'` write but
was rejected by GitHub at workflow runtime. Debugging consumed ~30
minutes and exposed a class of failures (token revoked, scope missing,
format malformed) that are all silent at write time and loud at use
time.

To close this gap, `ensure_project_token()` now performs a **live
GitHub API ping** immediately after the secret write:

```bash
http_code="$(curl -fsS -o /dev/null -w '%{http_code}' \
  --max-time 10 \
  -H "Authorization: Bearer $token" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/user 2>/dev/null || echo "000")"
```

Mapping:

| HTTP | Meaning | Action |
|---|---|---|
| 200 | Token valid and authenticates | `ok` log, continue init |
| 401 | Token rejected (revoked, expired, malformed) | `fail` with regenerate-PAT instruction |
| 403 | Authenticated but lacks scope | `fail` with scope guidance |
| 000 | Network unreachable / timeout | `fail` with connectivity hint |
| other | Unexpected response | `fail` with diagnostic prompt |

The check fires on the live token (not the secret), because the secret
is write-only via `gh secret set`. A passing local check effectively
guarantees the secret is identical (same bytes that just authenticated)
and will work in the workflow runner. The 10-second timeout prevents
the init script hanging on network issues; `--max-time` is a hard cap.

**Skip conditions still honored:** `DRY_RUN=1` and
`DEV_STUDIO_SKIP_PROJECT_TOKEN=1` both skip the entire
`ensure_project_token()` function, including the health check.

### End-to-end canary workflow (added 2026-06-15, after second failure)

The §3.4 live health-check uses `$token` from the running shell. We caught
a new failure mode where the **local** ping returned HTTP 200 (the in-memory
variable was valid) but **every** subsequent board-sync workflow on the same
project failed with HTTP 401 Bad credentials. The cause: `gh secret set
--body -` reads stdin verbatim. A pasted token that arrives with a trailing
CR byte (Windows clipboard), a UTF-8 BOM (some terminal emulators), or
leading/trailing whitespace gets stored byte-for-byte. The runner reads the
secret unchanged into `${{ secrets.PROJECT_TOKEN }}`, the resulting
`Authorization: Bearer <corrupted>` header is malformed, and GitHub returns
401. The local ping never sees the corruption because it uses the still-
clean shell variable.

Two-layer fix:

1. **Input sanitization** (defensive). Before writing the secret, strip the
   known-bad bytes from `$token`: UTF-8 BOM at start, all CR bytes, all
   newlines, leading/trailing ASCII whitespace. Implementation:
   ```bash
   token="${token#$'\xef\xbb\xbf'}"
   token="${token//$'\r'/}"
   token="${token//$'\n'/}"
   token="${token#"${token%%[![:space:]]*}"}"
   token="${token%"${token##*[![:space:]]}"}"
   ```
   This eliminates the most common paste-corruption modes. Format
   validation (`ghp_*` / `github_pat_*`) catches anything left over.

2. **End-to-end canary workflow** (deterministic). A new workflow
   `.github/workflows/secret-canary.yml` runs on `workflow_dispatch`. It
   reads `${{ secrets.PROJECT_TOKEN }}` on the runner and:
   - asserts non-empty and length >= 30
   - pings `api.github.com/user` (must return HTTP 200)
   - runs a minimal GraphQL query against `viewer.projectsV2` (must not
     return `errors[]` with INSUFFICIENT_SCOPES)

   The init script's `run_secret_canary()` dispatches this workflow after
   `install_systemd_watchers` (the last step before `summary`), polls for
   the new run id (max 30s), and watches the run to completion (max 90s).
   If conclusion != `success`, init aborts with a precise error pointing
   to the run URL.

   This is the *only* way to validate the secret end-to-end without
   exposing the value (GitHub correctly disallows reading secret bodies).
   Layer 1 prevents the bug; layer 2 catches anything that slips through.

**Why dispatch on `workflow_dispatch` (not `push`):** The init script needs
to know exactly which run id to watch. Push events produce runs whose ids
are not directly returned to the dispatcher; reverse-looking-them-up by
timestamp is racy. `workflow_dispatch` accepts an opaque `bootstrap_id`
input that lets us correlate runs to bootstrap sessions even if multiple
dev-studio-init invocations happen close together.

**Failure UX:** canary failures hard-abort init with a printable Actions
run URL. The user re-runs `new-project.sh` and re-pastes the token. If it
still fails the PAT itself is likely revoked or missing scopes — the
canary's distinct exit codes (3/4/5/6/7/8) point to the precise root cause.

**Skip conditions still honored:** `DRY_RUN=1` and
`DEV_STUDIO_SKIP_PROJECT_TOKEN=1` skip the canary along with the rest of
`ensure_project_token()` machinery.

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
