# ADR-0007: Auto Label Cleanup via GitHub Action

**Status:** Accepted
**Date:** 2026-06-11
**Owners:** atilcan (operator), watcher fleet (consumers)
**Supersedes:** none
**Related:** ADR-0002 (GitHub-native autonomy), ADR-0003 (event model v2), ADR-0005 (pr_merged events), ADR-0006 (watcher resilience)

## Context

The Multi-Agent Dev Studio uses GitHub labels as the primary signaling
channel between operator, watchers, and Claude Code role instances. After
several sprints we accumulated three categories of label noise:

1. **Transient signaling labels** (`cc:*`, `agent:*`, `needs-*`,
   `agent-stall`) stay attached after a PR is merged or an issue is
   closed, so subsequent label-conditional logic (PR-D D2.1.1, planned)
   would re-fire on already-finished work.
2. **Status lifecycle labels** (`status:in-progress`, `status:in-review`,
   `status:ready`, `status:blocked`, `status:backlog`) never advance to
   `status:done` automatically, requiring manual hygiene.
3. **Watcher dedup pressure** — every stale label that gets touched
   later (e.g. a comment) re-enters event dedup ring buffers and
   competes with real events.

Without cleanup, the autonomous loop slowly degrades. The "garantili
otomasyon" promise breaks the moment an operator must remember to
strip labels by hand.

## Decision

Add a GitHub Action workflow (`.github/workflows/label-cleanup.yml`)
that triggers on `pull_request: closed` (merged only) and
`issues: closed`, and:

- **Removes** any label matching `^(cc:|agent:|needs-)|^agent-stall$`
- **Advances** any `status:(in-progress|in-review|ready|blocked|backlog)`
  to `status:done` — but only on merged PRs, not closed issues
- **Preserves** everything else (`type:*`, `priority:*`, `sprint:*`,
  `security`, `good-first-issue`, `status:done`)

Closed-but-not-merged PRs leave labels intact so an operator can review
why the PR was abandoned.

## Chosen design (1-C + 2-Z + 3-OK from D3 design conversation)

- **1-C Hybrid taxonomy**: transient label families auto-clean, metadata
  preserved. Granular enough to be useful, simple enough to not need
  per-role coordination.
- **2-Z GitHub Action**: cleanup runs in GitHub Actions, not inside
  watchers. This decouples cleanup from Claude Code session liveness,
  from systemd unit state, and from the VM being online.
- **3 Taxonomy ratified** against actual `gh label list` output as of
  2026-06-11. See "Label taxonomy" below.

## Label taxonomy

| Family | Examples | On PR merge | On issue close |
|---|---|---|---|
| `cc:*` | `cc:developer`, `cc:pm` | Remove | Remove |
| `agent:*` | `agent:developer`, `agent:tester` | Remove | Remove |
| `needs-*` | `needs-architect-review`, `needs-tester-signoff`, `needs-human` | Remove | Remove |
| `agent-stall` | — | Remove | Remove |
| `status:in-progress`/`in-review`/`ready`/`blocked`/`backlog` | — | Replace with `status:done` | Untouched |
| `status:done` | — | Untouched | Untouched |
| `type:*` | `type:bug`, `type:feature` | Preserve | Preserve |
| `priority:*` | `priority:P0..P3` | Preserve | Preserve |
| `sprint:*` | `sprint:current` | Preserve | Preserve |
| `security`, `good-first-issue` | — | Preserve | Preserve |

## Alternatives considered

- **Watcher-side cleanup (option 2-X)**: each role drops its own
  `cc:<role>` after finishing. Pro: distributed, no central dependency.
  Con: requires every role to be alive at the right moment; fails if a
  Claude Code session is offline; couples cleanup to watcher state we
  just hardened in D4.
- **Janitor role (option 2-Y)**: one role periodically sweeps closed
  PRs. Pro: simple central logic. Con: still depends on Claude Code
  session liveness, polls instead of reacts.
- **Aggressive cleanup (option 1-A)**: strip *all* labels on merge.
  Rejected — loses analytical metadata (type, priority, sprint), which
  we rely on for retrospectives and sprint review.

## Failure modes

| Scenario | Behaviour |
|---|---|
| Action fails (network, rate limit) | Labels persist; next merge retries on its own PR. No watcher impact — labels just stay until next operator pass or next merge cycle. |
| Label already missing | `gh api DELETE` returns 404; logged as warning, not failure. |
| `status:done` add fails | Warning only; the transient removals still succeed. |
| Closed-not-merged PR | Job skipped entirely (if-clause). Operator can inspect labels for diagnosis. |
| Issue closed | Transient labels removed; status labels untouched (issues use status taxonomy differently). |

## Audit & observability

- Each Action run logs current labels, the list of labels to remove,
  per-label remove result, and final label state — all in collapsible
  groups in the GitHub Actions UI.
- Workflow runs are visible at
  `https://github.com/<repo>/actions/workflows/label-cleanup.yml`.
- No new files outside `.github/workflows/` — zero footprint on the VM.

## Migration

- Zero-touch on the VM. Watcher fleet does not need restart, install
  script does not change, no systemd units modified.
- On the first merge after this PR lands, the Action runs against the
  PR that introduced it — a self-test by construction.
- Existing PRs/issues with stale transient labels remain stale until
  they next change state (merge/close). This is acceptable; D3 fixes
  the *future*, not the past. A backfill script may be added later if
  needed (not in scope).

## Template-grade considerations

This Action is fully self-contained:

- No secrets beyond the default `GITHUB_TOKEN`
- No dependencies on the repo's directory layout
- Label taxonomy is regex-driven; reusing this template only requires
  matching the `cc:*`, `agent:*`, `needs-*` convention (and the
  `status:*` advancement, optional)
- Copy `.github/workflows/label-cleanup.yml` to a new repo, done

## Rollback

Delete `.github/workflows/label-cleanup.yml` and merge. No state to
unwind.

## Future work (deferred)

- **D2.1.1 label-conditional fanout**: depends on D3 because we need
  guaranteed-clean label state before architect/tester wake conditions
  become trustworthy.
- **Backfill script**: optional one-shot to clean stale labels on
  already-merged PRs and already-closed issues. Low priority — the
  forward-only behaviour is acceptable.
- **Label history audit**: emit a structured event to a log file or
  Telegram on each cleanup, for review traceability. Currently only
  visible in Actions UI.
