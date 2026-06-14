# ADR-0013 — Sync `status:*` Labels to Projects v2 Board Status Field

**Status:** Accepted (auth section superseded by ADR-0014)
**Date:** 2026-06-14
**Supersedes:** —
**Related:** ADR-0007 (Label Cleanup), ADR-0012 (Required Label Set), ADR-0014 (PROJECT_TOKEN secret)

> **Note (2026-06-14):** The original auth design used `secrets.GITHUB_TOKEN`,
> which was empirically proven insufficient — default workflow tokens cannot
> mutate ProjectsV2 (NOT_FOUND on the `projectV2(number:)` query). The auth
> mechanism was replaced by **ADR-0014** which provisions a `PROJECT_TOKEN`
> classic PAT (scopes `repo` + `project`) as a repo secret during init. The
> rest of this ADR — the label-to-option mapping, selection rule, and workflow
> structure — remains accurate.

---

## Context

The dev-studio template uses two parallel concepts for "where is this
work in the flow":

1. **Repository labels** of the form `status:backlog`, `status:ready`,
   `status:in-progress`, `status:in-review`, `status:blocked`,
   `status:done`. Agents flip these as part of the handoff
   discipline (ADR-0009).
2. **GitHub Projects v2 "Status" field** with options `Backlog`,
   `Ready`, `In Progress`, `In Review`, `Done` (seeded by
   `scripts/bootstrap-project-board.sh`).

GitHub does **not** sync these by default. A separate, manual,
per-project workflow ("Auto-set status from labels") exists in the
GitHub Projects UI, but it is configurable only through the web UI,
has no public API, and resets to off whenever a board is recreated.
Concrete failure observed on 2026-06-14 in `AtilCalculator`: agents
correctly flipped `status:backlog` on three issues, but the board
cards stayed in the "No Status" lane because nothing translated
labels to the field.

The result is a split-brain board where:

- Agents read/write the **label** correctly,
- Humans look at the **board column** and see nothing,
- Board automation rules (Auto-add, Item-closed → Done) only operate
  on field values, so closing an issue with `status:in-progress`
  label *still* leaves the card stuck because nothing updated the
  field.

## Decision

Ship a `status-label-to-board.yml.tmpl` GitHub Actions workflow as
part of the template. On every issue/PR `labeled` or `unlabeled`
event, the workflow:

1. Reads the issue/PR's current `status:*` label set.
2. Resolves the Projects v2 item ID for the issue/PR on the project
   board configured for the repo.
3. Sets the project's Status field to the matching option
   (`status:backlog` → `Backlog`, etc.).
4. If the issue/PR has no `status:*` label, the workflow no-ops
   (leaves the field as-is, so a manual GUI move is not clobbered).
5. If the issue/PR has *multiple* `status:*` labels, the workflow
   picks the most-advanced one (`done > in-review > in-progress >
   blocked > ready > backlog`) and comments a warning that
   `status:*` should be mutually exclusive (ADR-0012 future work).

The workflow is templated (`.tmpl`) because the project number is
project-specific and is injected at `dev-studio-init.sh` render
time. The renderer reads the project number from the env variable
`GITHUB_PROJECT_NUMBER`, which `scripts/bootstrap-project-board.sh`
already exports after creating the board.

### Workflow inputs

| Input | Source | Purpose |
|---|---|---|
| `PROJECT_OWNER` | `{{GITHUB_OWNER}}` template var | Whose user/org owns the project |
| `PROJECT_NUMBER` | `{{GITHUB_PROJECT_NUMBER}}` template var | Which board to update |
| `STATUS_FIELD_NAME` | hard-coded `Status` | Field name (board is seeded by bootstrap script) |
| `GH_TOKEN` | `secrets.GITHUB_TOKEN` | Auth |

### Label → field-option mapping

```
status:backlog      → Backlog
status:ready        → Ready
status:in-progress  → In Progress
status:in-review    → In Review
status:blocked      → Blocked       (board option, added by bootstrap if missing)
status:done         → Done
```

### Why not use a third-party Action?

Two third-party actions in the wild do this
(`@github/update-projects-action`, `@titoportas/update-project-fields`),
but both require either a PAT scoped to `project` (cannot be the
default `GITHUB_TOKEN`) or are unmaintained. The first-party
`actions/github-script@v7` plus GraphQL is ~120 lines and uses only
the default token — same model as `label-cleanup.yml`.

## Consequences

### Positive

- Board columns and `status:*` labels are always in sync. Humans
  filtering by column see the same set of work as agents filtering
  by label.
- The existing manual GUI workflow ("Auto-add to project") can stay
  enabled because it operates on issue creation only; this new
  workflow handles every subsequent label change.
- Items closed in a non-`Done` state (e.g. a `wontfix` issue still
  carrying `status:in-progress`) are visible as outliers on the
  board — which is what we want.

### Negative

- Adds a one-time manual step at project creation: the human must
  ensure `GITHUB_PROJECT_NUMBER` is set in the rendered workflow.
  `dev-studio-init.sh` already extracts this from the bootstrap
  script output, so this is automated for the template-rendered path.
- Workflow runs on every label event — ~6 events per issue lifecycle.
  Quota impact: well within the free-tier 2000 minutes/month even for
  a 50-story sprint.

### Out of scope

- Bidirectional sync (board move → label set). Considered, rejected:
  GitHub Projects v2 field changes do not currently emit reliable
  webhook events, and the agent loop already drives flow via labels,
  so the human moving a card by hand is a rare manual override that
  doesn't need automation back.
- Replacing labels with field-only state. Considered, rejected:
  labels are filterable on every API endpoint (`gh issue list
  --label status:in-progress`), agents already act on label changes,
  and ADR-0002's autonomy loop is label-driven. The board is the
  *view*, labels are the *state*.

## Future work

- Add a CI assertion that exactly one `status:*` label is present on
  every open issue/PR (ADR-0012 future work) — once that lands,
  remove the "pick most-advanced" branch in this workflow.
- Add a board column for `status:blocked` if it does not yet exist
  (bootstrap script should be updated to seed it; currently it seeds
  the 5 happy-path columns only).
