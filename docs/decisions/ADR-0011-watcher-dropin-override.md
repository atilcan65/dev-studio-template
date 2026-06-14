# ADR-0011 — Watcher Per-Instance Configuration via Drop-In Override

**Status:** Accepted
**Date:** 2026-06-14
**Supersedes:** _(implementation detail of ADR-0010 — does not supersede)_
**Related:** ADR-0010 (Per-Project Systemd Watchers)

---

## Context

ADR-0010 introduced per-project systemd watcher instances
(`dev-studio-watcher@<project>--<role>.service`) configured via per-instance
`EnvironmentFile` at `~/.config/dev-studio/instances/<instance>.env`. The
base unit template referenced env vars in several places:

```ini
EnvironmentFile=%h/.config/dev-studio/instances/%i.env
WorkingDirectory=${REPO_ROOT}
ExecStart=/usr/bin/bash ${REPO_ROOT}/scripts/agent-watch.sh ${ROLE} --loop
StandardOutput=append:${DEV_STUDIO_HEARTBEAT_DIR}/${ROLE}.watch.log
StandardError=append:${DEV_STUDIO_HEARTBEAT_DIR}/${ROLE}.watch.log
```

When bootstrapping AtilCalculator post-ADR-0010, all 5 watcher units
failed at unit-load time:

```
/home/atilcan/.config/systemd/user/dev-studio-watcher@.service:12:
  WorkingDirectory= path is not absolute: ${REPO_ROOT}
dev-studio-watcher@AtilCalculator--product-manager.service:
  Unit configuration has fatal error, unit will not be started.
```

### Root cause

systemd's `EnvironmentFile=` variables are expanded **only inside
`ExecStart=`, `ExecStop=`, `ExecReload=`** (and a few other Exec*
directives). Settings parsed at unit-load time — `WorkingDirectory=`,
`StandardOutput=append:PATH`, `StandardError=append:PATH`, `BindPaths=`,
`ReadWritePaths=`, etc. — require **absolute, literal paths** when the
unit file is parsed. They are not expanded from `EnvironmentFile`.

This is documented behaviour:

> systemd.exec(5), VARIABLE SUBSTITUTION:
> "Variables to be substituted must be enclosed in `${}` or `$`. Note that
> the latter form is not recognized in environment variables, only on the
> command lines (i.e. `ExecStart=` and similar settings)."

ADR-0010's design treated `EnvironmentFile` as a universal substitution
mechanism. It is not.

## Decision

Keep the per-instance `EnvironmentFile` (it still serves a purpose: exporting
env vars to `agent-watch.sh` at process startup). **Additionally**, write a
per-instance **drop-in override** at install time with rendered absolute
paths:

```
~/.config/systemd/user/dev-studio-watcher@<project>--<role>.service.d/override.conf
```

Drop-in contents (example for `AtilCalculator--product-manager`):

```ini
[Service]
WorkingDirectory=/home/atilcan/projects/AtilCalculator
# Reset ExecStart first (drop-ins are additive otherwise), then set ours.
ExecStart=
ExecStart=/usr/bin/bash /home/atilcan/projects/AtilCalculator/scripts/agent-watch.sh product-manager --loop
StandardOutput=append:/var/log/dev-studio/AtilCalculator/product-manager.watch.log
StandardError=append:/var/log/dev-studio/AtilCalculator/product-manager.watch.log
```

The base template `dev-studio-watcher@.service.tmpl` is **deliberately
incomplete** — it omits `WorkingDirectory`, `ExecStart`, and
`StandardOutput/Error`. Starting an instance without its drop-in fails with
"Service has no ExecStart= setting, refusing." This is the intended safety
net: forgetting to run the installer becomes a loud failure instead of
silent path resolution drift.

### Why drop-in (not other alternatives)

systemd has multiple per-instance customization mechanisms; drop-in
override.conf is the canonical one. Alternatives considered:

#### Alternative 1 — Render full unit file per instance (rejected)

Generate `dev-studio-watcher-<project>--<role>.service` (no `@` template)
with absolute paths baked in. 5 files per project.

**Rejected:** doubles maintenance cost. Any future change to the base
contract (Restart policy, MemoryMax, KillMode) must be applied to N files
across M projects. Drop-in keeps one source of truth for shared settings.

#### Alternative 2 — Wrapper shell script as ExecStart (rejected)

`ExecStart=/usr/bin/bash %h/.config/dev-studio/instances/%i.sh` where the
`.sh` sources its own env file, `cd`s to repo, then `exec`s
`agent-watch.sh`. No `WorkingDirectory` in unit.

**Rejected:** introduces an extra process layer; complicates signal
handling (the wrapper must `exec` correctly to avoid double-fork on stop);
violates "use systemd primitives where they exist" principle; doesn't help
with `StandardOutput=append:PATH` which still needs absolute path.

#### Alternative 3 — Use a separate `.conf` directory parsed by a custom
`ExecStartPre` script (rejected)

Custom mechanism on top of systemd's standard mechanism. No benefit.

#### Alternative 4 — Symlink farm per project (rejected)

Symlink `/home/atilcan/projects/<proj>` → `/var/lib/dev-studio/active` and
hardcode `WorkingDirectory=/var/lib/dev-studio/active`.

**Rejected:** "active project" concept is exactly what ADR-0010 eliminates.
Only one symlink target at a time, so only one project active. Breaks
parallel multi-project goal.

### Drop-in chosen — this ADR.

## Consequences

### Positive

- **Works.** Drop-in `WorkingDirectory=` is an absolute path at unit-parse
  time. No env-var expansion needed.
- **Standard mechanism.** `systemctl --user edit dev-studio-watcher@<inst>`
  produces overrides in the same directory; users can layer additional
  tweaks (e.g. `MemoryMax=1G` for a heavy agent) without touching the
  installer-generated `override.conf`.
- **Failure is loud.** Missing drop-in → "no ExecStart" refusal at start,
  not a silent fallback to wrong WorkingDirectory.
- **EnvironmentFile preserved.** `agent-watch.sh` still receives
  `REPO_ROOT`, `ROLE`, `PROJECT`, `DEV_STUDIO_HEARTBEAT_DIR`,
  `AGENT_STATE_DIR` as shell env vars (they're still useful inside the
  watcher loop).

### Negative / Risks

- **One more file per instance.** 5 watchers per project × 1 override.conf
  + 1 env file = 10 files per project under `~/.config/`. Acceptable.
- **Two sources of truth for some values.** `REPO_ROOT` appears in both
  the env file (for `agent-watch.sh`) and the drop-in (for `ExecStart` /
  `WorkingDirectory`). The installer writes both from one source; user
  hand-editing one without the other will cause drift. Mitigation: header
  comment in both files says "regenerated by installer; re-run installer
  to update."
- **Re-running installer overwrites operator's manual drop-in tweaks if
  they edited `override.conf` directly.** Mitigation: documentation
  directs operators to use `systemctl --user edit <unit>` (which creates
  a separate `<num>-name.conf` in the same drop-in dir) for personal
  tweaks. Those survive re-install.

## Implementation summary

Files touched (in this ADR's PR):

- `scripts/install/systemd/dev-studio-watcher@.service.tmpl` —
  `WorkingDirectory`, `ExecStart`, `StandardOutput`, `StandardError`
  removed. Added a prominent comment block explaining the drop-in
  contract. `Documentation=` line for ADR-0011 added.
- `scripts/install/dev-studio-install-systemd.sh` — new stage "writing
  per-instance drop-in overrides" after env-file stage. Writes
  `$SYSTEMD_USER_DIR/dev-studio-watcher@<inst>.service.d/override.conf`
  with absolute paths.
- `scripts/install/dev-studio-uninstall-systemd.sh` — `rm -rf` the drop-in
  directories during normal uninstall (not just `--purge`).
- `docs/decisions/INDEX.md.tmpl` — ADR-0011 listed.

## Acceptance Test

After this ADR ships and `dev-studio-install-systemd.sh` is re-run for a
project:

1. `systemctl --user cat dev-studio-watcher@<proj>--product-manager.service`
   shows base unit + drop-in concatenated; `WorkingDirectory=` is an
   absolute path.
2. `systemctl --user start dev-studio-watcher@<proj>--product-manager.service`
   succeeds (no unit-load error).
3. `systemctl --user is-active dev-studio-watcher@<proj>--product-manager.service`
   returns `active`.
4. `journalctl --user -u dev-studio-watcher@<proj>--product-manager.service`
   shows agent-watch.sh starting, no parse errors.
5. Manually removing the drop-in dir and `systemctl --user restart` fails
   with "no ExecStart=" — confirming the safety net.

## Relationship to ADR-0010

ADR-0010 ("Per-Project Systemd Watchers") established the topology
(instance naming, per-project log dirs, auto-install during bootstrap,
legacy migration). ADR-0010 remains Accepted; this ADR refines its
configuration mechanism. No part of ADR-0010 is superseded — only the
implementation of "per-instance config" gains a second layer (drop-in
in addition to env file).
