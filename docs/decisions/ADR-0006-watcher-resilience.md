# ADR-0006: Watcher Resilience (systemd --user + auto-reload)

- Status: Accepted
- Date: 2026-06-11
- Deciders: orchestrator + human operator
- Refs: ADR-0002 (GitHub-Native Autonomy), ADR-0005 (PR-Merged Events)

## Context

The Multi-Agent Dev Studio runs five `agent-watch.sh` instances — one per role —
that poll GitHub for wake-up events. Until D4 these were launched as detached
`nohup bash agent-watch.sh <role> --loop &` from `dev-studio-start.sh`.

Three template-grade failures of that model surfaced during PR-D rollout:

1. **No restart-on-change.** When PR #35 (D2) and PR #36 (D2.1) merged, the
   watchers on the VM kept running their pre-merge bash code in memory. The
   operator had to `pkill -f agent-watch.sh && nohup ...` by hand to pick up
   the new logic. This ritual is invisible to anyone reading the README and
   does not scale beyond a handful of agents.
2. **No restart-on-crash.** A gh-CLI segfault, a transient network failure
   that crashes the shell, or any `kill` from elsewhere on the VM silently
   ends an agent's wake-up loop. The only signal is heartbeat staleness,
   detected minutes later by the human.
3. **No restart-on-reboot.** `nohup` survives logout but not a VM reboot.
   Every reboot requires `dev-studio-start.sh` to be re-run, which is yet
   another item on the "don't forget" list.

The user's stated goal is that this stack be **template-grade** — usable for
new projects with no manual ops. The nohup pattern violates that.

## Decision

Use **systemd --user** to manage all five watcher processes. Use a **`.path`
unit** to automatically restart all watchers whenever `agent-watch.sh` changes
on disk (e.g. after `git pull` brings in a new version).

### Components

1. **`dev-studio-watcher@.service`** — templated user unit. One instantiation
   per role (`%i`). `Restart=always`, `RestartSec=5`, `StartLimitBurst=10` —
   recovers from crashes within 5s but stops the spiral if the script itself
   is broken. Resource caps `MemoryMax=512M` / `TasksMax=64` guard against a
   rogue watcher eating the VM. Logs append to `/var/log/dev-studio/%i.watch.log`
   (same path as before, for backward compatibility).

2. **`dev-studio-watcher-reload.path`** — watches `agent-watch.sh` for changes
   via inotify (`PathChanged=`). Fires on `IN_CLOSE_WRITE` and `IN_MOVED_TO`,
   which covers both editor saves and atomic file replacement by `git pull`.

3. **`dev-studio-watcher-reload.service`** — `Type=oneshot` triggered by the
   `.path` unit. A 2-second `ExecStartPre=sleep` debounces multi-write bursts
   (e.g. `git pull` quickly touching the same file twice during checkout).
   Then issues a single `systemctl --user restart` for all five role units in
   one call. Appends an audit line to `/var/log/dev-studio/watcher-reload.log`
   so post-mortems are easy.

4. **`scripts/install/dev-studio-install-systemd.sh`** — one-shot installer.
   Idempotent. Copies unit files to `~/.config/systemd/user/`, kills any legacy
   nohup watchers, enables and starts the five role services, enables the
   reload path. Optional `INSTALL_ENABLE_LINGER=1` arms `loginctl enable-linger`
   for boot-time start (operator opts in; needs sudo).

5. **`scripts/dev-studio-start.sh`** — modified to detect systemd units. If
   `dev-studio-watcher@orchestrator` is enabled, the script now `systemctl
   --user start`s each role instead of forking nohup. Old nohup code path is
   retained as a fallback for VMs where the installer has not yet been run.

6. **`scripts/agent-doctor.sh`** — `--kick <role>` now prefers
   `systemctl --user restart`; falls back to nohup only when no unit is active.
   `--all` prints `systemctl --user list-units 'dev-studio-watcher@*'` for
   one-glance health.

### Decisions taken (operator-approved)

- **Linger ON by default** (operator opts in via `INSTALL_ENABLE_LINGER=1`,
  installer prints the manual command otherwise). Boot-safe reuse is critical
  for the template.
- **Single-file watch.** Only `agent-watch.sh` is watched by the `.path` unit.
  Adding `agent-state.sh` or other helpers later is a one-line `PathChanged=`
  addition; until then, those changes still require an explicit
  `systemctl --user restart` (rare).
- **Hard cutover.** The installer `pkill`s legacy watchers before enabling
  systemd units. The 5–10s polling gap is invisible (poll cadence is 60s).

## Consequences

### Positive

- **PR merge auto-deploys watcher code.** Every future `agent-watch.sh` change
  now takes effect within ~3–5s of `git pull`, with no operator action.
  Eliminates the entire pkill+nohup ritual.
- **Crash recovery.** Any watcher death is healed within 5s by `Restart=always`.
  Heartbeat-stale alerts now indicate a real problem (network, GitHub
  outage, runaway loop) rather than "operator forgot to restart".
- **Boot-safe.** With linger enabled, a VM reboot brings the multi-agent loop
  back online without operator login.
- **Observable.** `systemctl --user status`, `journalctl --user -u`, and
  `agent-doctor.sh --all` give consistent UX for inspecting watcher health.
  No more `ps -ef | grep` archaeology.
- **Template-grade.** A new project clones the repo, runs the installer once,
  and inherits the same resilience guarantees. The README addition is two
  commands.

### Negative

- **Adds systemd as a hard dependency** for the resilience features.
  `nohup` fallback in `dev-studio-start.sh` keeps the system bootable on
  unusual environments (containers without `--user` systemd, e.g. some CI),
  but loses crash/reboot recovery.
- **inotify on a git-managed file has edge cases.** Some git operations
  (e.g. `git checkout` of a branch where the file is unchanged) do NOT
  emit `IN_CLOSE_WRITE`. The 2-second debounce + manual `systemctl restart`
  escape hatch cover the residual cases.
- **Operator confusion if both modes are active.** Mitigated by the
  installer's pkill step and by `dev-studio-start.sh` preferring systemd
  when units are present.

### Risks accepted

- A watcher restart loop (e.g. script crashes immediately on start) would
  hit `StartLimitBurst=10 / StartLimitIntervalSec=60` and stop. The unit
  enters `failed` state until manually reset (`systemctl --user reset-failed`).
  This is preferable to a tight infinite respawn that masks the real bug.
- Resource caps (`MemoryMax=512M`, `TasksMax=64`) are generous for a
  poll-and-fork-gh loop; a future heavy watcher feature might need a
  drop-in override.

## Migration

On any VM running the legacy nohup setup:

```bash
cd /opt/dev-studio/atilprojects
git checkout main && git pull --ff-only
bash scripts/install/dev-studio-install-systemd.sh
# Optional, recommended:
sudo loginctl enable-linger $USER
```

Subsequent PRs touching `agent-watch.sh` need no follow-up commands.

## Verification

See `PR-D-D4-DEPLOY.md` smoke-test section: install, kill a watcher, confirm
respawn; `touch agent-watch.sh`, confirm fan-out restart; merge a no-op PR,
confirm orchestrator/PM/developer panes wake without operator action.

## Follow-ups (out of scope)

- **D4.1** `sd_notify` / `WatchdogSec` from inside `agent-watch.sh` to detect
  livelock (process alive but loop stuck). Requires extending `agent-state.sh`
  to call `systemd-notify` on each successful poll.
- **D4.2** Watch additional scripts (`agent-state.sh`, `notify.sh`) via the
  same `.path` unit (one-line change once justified).
- **D4.3** Switch the per-role log file from `append:/var/log/...` to
  `journal` and use `journalctl --user-unit dev-studio-watcher@developer`
  for unified log search.
