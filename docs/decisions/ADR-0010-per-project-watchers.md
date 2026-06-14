# ADR-0010 — Per-Project Systemd Watchers

**Status:** Accepted
**Date:** 2026-06-14
**Supersedes:** ADR-0006 (in part — see "Relationship to ADR-0006" below)
**Related:** ADR-0002 (GitHub-Native Autonomy), ADR-0003 (Event Model v2)

---

## Context

Dev Studio is **template-grade infrastructure**: a single user (or team) runs
multiple projects concurrently, each cloned from `dev-studio-template` via
`dev-studio-launcher`. Each project lives in its own GitHub repo and its own
local working directory (e.g. `/opt/dev-studio/AtilCalculator`,
`/opt/dev-studio/another-project`).

ADR-0006 introduced systemd-managed `agent-watch.sh` loops via a templated
unit `dev-studio-watcher@.service` instantiated **per role**:

```
dev-studio-watcher@product-manager.service
dev-studio-watcher@developer.service
dev-studio-watcher@architect.service
dev-studio-watcher@tester.service
dev-studio-watcher@orchestrator.service
```

This worked for the first project (`atilprojects`) because the unit hardcoded
`WorkingDirectory=/opt/dev-studio/atilprojects` and called
`/opt/dev-studio/atilprojects/scripts/agent-watch.sh`.

**The break:** When a second project (`AtilCalculator`) was bootstrapped on
the same VM, `dev-studio-start.sh` detected that systemd units were already
enabled and entered "systemd mode" — but the existing watcher units still
pointed at the **old project's** repo. AtilCalculator's PM watcher never ran;
Issue #1 sat in the backlog with no agent picking it up. The user observed
the PM agent idle in tmux while the GitHub Issue was clearly labelled
`agent:product-manager + status:backlog`.

Logs (`/var/log/dev-studio/*.watch.log`) were also shared across projects,
producing interleaved output with no project namespace.

We need an architecture where:

1. **N projects on one host can coexist**, each with its own watcher loops.
2. **Switching the "active project" is no longer possible** — every project
   that has been bootstrapped is independently watched.
3. **The same dev-studio-template tarball works for every project** —
   no per-host hand-editing of unit files.
4. **Existing projects (e.g. atilprojects) keep working** during the
   transition.

## Decision

Adopt **per-project systemd watcher instances** keyed by
`<project>--<role>` (double-dash separator):

```
dev-studio-watcher@AtilCalculator--product-manager.service
dev-studio-watcher@AtilCalculator--developer.service
…
dev-studio-watcher@another-project--product-manager.service
…
```

The watcher unit is **generic**. Per-instance configuration lives in env
files, one per instance:

```
~/.config/dev-studio/instances/<project>--<role>.env
```

Each env file exports:

| Variable | Purpose |
|----------|---------|
| `REPO_ROOT` | Absolute path to the project's working copy |
| `ROLE` | One of: product-manager, developer, architect, tester, orchestrator |
| `PROJECT` | Project name (typically `basename "$REPO_ROOT"`) |
| `DEV_STUDIO_HEARTBEAT_DIR` | `/var/log/dev-studio/<project>` |
| `AGENT_STATE_DIR` | `/var/log/dev-studio/<project>/agent-state` |

The unit file (`dev-studio-watcher@.service.tmpl`) reads these via
`EnvironmentFile=%h/.config/dev-studio/instances/%i.env` and substitutes
them into `WorkingDirectory`, `ExecStart`, and `StandardOutput/Error`.

### Reload trigger (per project, runtime-generated)

systemd `.path` units **cannot expand environment variables** in `PathChanged=`
or `PathExists=` lines. We therefore generate one pair of reload units **per
project** at install time:

```
~/.config/systemd/user/dev-studio-watcher-reload-<project>.path
~/.config/systemd/user/dev-studio-watcher-reload-<project>.service
```

The `.path` watches `<REPO_ROOT>/scripts/agent-watch.sh` and the `.service`
restarts only that project's five watcher instances when it changes. This
keeps the ADR-0006 "auto-reload on agent-watch.sh change" property without
cross-project coupling.

### Log layout

```
/var/log/dev-studio/
├── <project-A>/
│   ├── product-manager.watch.log
│   ├── developer.watch.log
│   ├── architect.watch.log
│   ├── tester.watch.log
│   ├── orchestrator.watch.log
│   ├── *.heartbeat
│   └── agent-state/
│       ├── product-manager.json
│       └── …
└── <project-B>/
    └── …
```

Every script that previously hardcoded `/var/log/dev-studio` now resolves
its log/state directory in this order:

1. Explicit env var (`DEV_STUDIO_HEARTBEAT_DIR`, `AGENT_STATE_DIR`)
2. `<DEV_STUDIO_HEARTBEAT_BASE>/<PROJECT_NAME>`
3. Default base `/var/log/dev-studio` + project name inferred from script
   location (`basename` of the repo containing `scripts/`)

This makes `agent-state.sh`, `agent-doctor.sh`, `health-check.sh`, and
`dev-studio-start.sh` work correctly when invoked from **any** project on the
host with zero configuration.

### Auto-install during bootstrap

`dev-studio-init.sh` now calls `install_systemd_watchers()` after
`bootstrap_board()`. This means a fresh project bootstrap end-to-end:

```
new-project.sh MyProj   # via dev-studio-launcher
↓
dev-studio-init.sh
├── render_all              (.tmpl → final)
├── verify                  (no unresolved placeholders)
├── git_init + push
├── bootstrap_board         (GH Projects v2)
└── install_systemd_watchers   ← NEW
    ├── write 5 env files
    ├── enable 5 watcher@<project>--<role>.service instances
    └── generate + enable per-project reload .path + .service
```

Opt-out: `DEV_STUDIO_SKIP_SYSTEMD=1` bash env before running init.

### Legacy migration

`dev-studio-install-systemd.sh` checks for the old non-project-keyed
instances (`dev-studio-watcher@<role>.service` and
`dev-studio-watcher-reload.path`) and disables them before installing the
new per-project units. The old unit files are left on disk (not removed) so
the user can audit; `dev-studio-uninstall-systemd.sh --purge` cleans them.

Opt-out: `MIGRATE_LEGACY=skip`.

### Templating

All hardcoded paths and project names in the template are replaced with
`{{HEARTBEAT_DIR}}` and `{{PROJECT_NAME}}` placeholders, rendered by
`dev-studio-init.sh`'s `render_one` at bootstrap time. Affected files:

- `.claude/agents/{product-manager,developer,architect,tester,orchestrator}.md.tmpl`
- `.claude/commands/standup.md.tmpl`
- `.claude/CLAUDE.md.tmpl`
- `scripts/kickoff/*.txt.tmpl` (5 files)
- `docs/{TROUBLESHOOTING,OPERATIONS}.md.tmpl`

This guarantees that after bootstrap, no rendered file references another
project's log dir or `atilprojects` by accident.

## Consequences

### Positive

- **N projects coexist on one VM** with independent watcher loops, logs,
  and state.
- **No more "active project" concept** — every bootstrapped project is
  independently observable.
- **Log isolation**: `journalctl --user-unit "dev-studio-watcher@MyProj--*"`
  or `tail -F /var/log/dev-studio/MyProj/*.watch.log` filters cleanly.
- **Zero hand-editing of unit files** per project — the template is
  fully turnkey.
- **Backward-compatible during migration**: old single-instance units are
  disabled, not destroyed.
- **`dev-studio-init.sh` auto-install** removes the "did the user remember
  to install systemd watchers?" footgun that caused the AtilCalculator PM
  to sit idle.

### Negative / Risks

- **More systemd units per host** (5 watcher instances + 2 reload units per
  project). At 10 projects = 70 user units. systemd handles this fine
  (units are cheap), but `systemctl --user list-units` output gets noisy.
  Mitigation: `systemctl --user list-units 'dev-studio-watcher@<project>--*'`
  filter pattern documented in OPERATIONS.md.
- **Env file is the source of truth**, not the unit file. Editing the unit
  template requires re-running `dev-studio-install-systemd.sh`; editing an
  env file requires `systemctl --user restart dev-studio-watcher@<project>--<role>`.
  Documented in TROUBLESHOOTING.md.
- **Runtime-generated reload units** are not in version control (they're
  written into `~/.config/systemd/user/` by the installer). The installer
  must be re-run if reload semantics change. Acceptable: install runs at
  bootstrap and on template upgrades.

### Operational notes

- View all watchers for a project:
  `systemctl --user list-units 'dev-studio-watcher@<project>--*'`
- Tail all logs for a project:
  `tail -F /var/log/dev-studio/<project>/*.watch.log`
- Disable one project's watchers (without uninstalling globally):
  `bash scripts/install/dev-studio-uninstall-systemd.sh --project <project>`
- Full clean (this project's instances + legacy units + state):
  `bash scripts/install/dev-studio-uninstall-systemd.sh --project <project> --purge`

## Relationship to ADR-0006

ADR-0006 ("Systemd-managed watcher resilience") is **superseded in
instance topology** by this ADR. The reliability properties of ADR-0006
(auto-restart on crash, auto-restart on `agent-watch.sh` change,
journal-based logging) are **preserved** — only the instancing scheme
changes from per-role-singleton to per-project--per-role.

A future ADR-0006 update should add a `Status: Superseded by ADR-0010 (for
instance topology)` header at the top of that document.

## Alternatives Considered

### A. Per-project drop-in override files (rejected)

`~/.config/systemd/user/dev-studio-watcher@<role>.service.d/override.conf`
per project, keyed by role only.

**Rejected:** drop-ins are additive, not switchable. Two projects can't
both set `WorkingDirectory=` on the same unit; systemd takes the last one
loaded. Would have required juggling drop-in files at "switch project"
time — exactly the failure mode that broke AtilCalculator.

### B. Single watcher process per role that iterates all projects (rejected)

One `dev-studio-watcher@product-manager.service` that scans every project
under `/opt/dev-studio/*` in a loop.

**Rejected:** failure of one project's watcher takes down all projects'
PMs for that role. Also breaks log isolation — single log file with
interleaved per-project output. Also fights systemd's normal restart
semantics.

### C. Keep ADR-0006 single-instance, document "one project per host" (rejected)

**Rejected:** explicit user request — "ben bu kurguyu kurduktan sonra
yarın öbür gün başka projelerde de bunu kullanacağım" (I'm going to use
this setup on other projects too in the days ahead). Template-grade means
multi-project from day one.

### D. Per-project chosen — this ADR.

## Acceptance Test

After this ADR ships:

1. `bash new-project.sh ProjectA` ✔ → 5 watchers active for ProjectA
2. `bash new-project.sh ProjectB` ✔ → 5 watchers active for ProjectB,
   ProjectA's 5 still running
3. `gh issue create -R atilcan65/ProjectA --label "agent:product-manager" --label "status:backlog" --title "test"` ✔ → ProjectA's PM watcher picks up within heartbeat interval (~60s); ProjectB's PM watcher does NOT pick it up
4. `systemctl --user restart dev-studio-watcher@ProjectA--developer.service` ✔ → only ProjectA's developer restarts; no other unit affected
5. Editing `scripts/agent-watch.sh` in ProjectA's repo ✔ → only ProjectA's 5 watchers reload (via per-project reload .path); ProjectB unaffected
