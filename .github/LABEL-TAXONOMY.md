# Label Taxonomy — dev-studio-template

> Mirror of [AtilCalculator's `.github/LABEL-TAXONOMY.md`](https://github.com/atilcan65/AtilCalculator/blob/main/.github/LABEL-TAXONOMY.md) (Issue #264, GAP KAPATMA port, P2).
> Canonical source: `atilcan65/AtilCalculator` (`scripts/bootstrap-labels.sh`).

This document describes the label set every project bootstrapped from
`dev-studio-template` MUST have, plus the rationale and the 4-category invariant
(ADR-0012) that enforces it.

## 4-Category Invariant (ADR-0012)

Every **open** issue and PR MUST carry exactly one label from each of these four
categories:

| Category    | Examples                                                            | Meaning                                                                 |
|-------------|---------------------------------------------------------------------|-------------------------------------------------------------------------|
| `type:*`    | `type:vision`, `type:feature`, `type:bug`, `type:chore`, `type:docs` | What kind of work this is                                              |
| `status:*`  | `status:backlog`, `status:ready`, `status:in-progress`, `status:in-review`, `status:blocked`, `status:done` | Where the work is in the flow                                          |
| `agent:*`   | `agent:orchestrator`, `agent:product-manager`, `agent:architect`, `agent:developer`, `agent:tester`, `agent:human` | Who owns the work (the assignee role)                                 |
| `cc:*`      | `cc:orchestrator`, `cc:product-manager`, `cc:architect`, `cc:developer`, `cc:tester`, `cc:human` | Top-of-the-funnel — who is currently expected to act                     |

CI enforces this: `.github/workflows/label-check.yml` (planned for a follow-up PR
pending owner approval — see Issue #264 acceptance criteria note).

## D2.2 Wake Labels

Two wake labels (added by the watcher loop on PR events):

| Label                       | Purpose                                                                                  |
|-----------------------------|------------------------------------------------------------------------------------------|
| `needs-tester-signoff`      | PR is awaiting Tester verdict; `pr_labeled` event wakes the Tester agent                 |
| `needs-architect-review`    | PR has architectural impact; `pr_labeled` event wakes the Architect agent                |

## Operational Labels

| Label            | Purpose                                                                          |
|------------------|----------------------------------------------------------------------------------|
| `priority:P0`    | Critical — blocks all work, fix immediately                                     |
| `priority:P1`    | High — fix this sprint                                                           |
| `priority:P2`    | Medium — fix next sprint                                                         |
| `priority:P3`    | Low — nice to have                                                               |
| `sprint:current` | Active sprint                                                                    |
| `sprint:next`    | Next sprint                                                                      |
| `sprint:backlog` | Future sprint                                                                    |
| `agent-stall`    | Agent stuck — needs human intervention                                           |
| `security`       | Security-sensitive — handle with care (do not auto-merge, route to architect)    |
| `good-first-issue` | Good for newcomers (human reviewers only)                                       |

## Bootstrapping

After cloning a fresh project from this template, run:

```bash
bash scripts/bootstrap-labels.sh owner/name
```

This is **idempotent** — it creates missing labels and updates descriptions on
existing ones. Safe to re-run on every Sprint 1 kickoff.

## Birth Contract

When opening a new issue or PR, you MUST apply all 4 category labels
(`type:*`, `status:*`, `agent:*`, `cc:*`) at creation time. Don't defer this to
"orchestrator will add it later" — the board sync workflow (ADR-0013) and the
autonomy loop (ADR-0002) both depend on every artefact having a complete label
set from the moment it's created.

## References

- ADR-0012: Required Label Set on Issue/PR Creation — the birth contract
- ADR-0013: Status-label → board sync
- ADR-0002: Autonomy Loop — GitHub-native wake-up
- D2.2: `pr_labeled` wake path via `needs-tester-signoff`
- AtilCalculator Issue #264 (GAP KAPATMA — this port)
