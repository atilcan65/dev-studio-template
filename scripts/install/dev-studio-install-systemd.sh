#!/usr/bin/env bash
# dev-studio-install-systemd.sh — per-project watcher installer
#
# Installs 5 systemd --user instances for this project:
#   dev-studio-watcher@<project>--<role>.service   (5 roles)
#   dev-studio-watcher-reload-<project>.{path,service}   (auto-reload on agent-watch.sh change)
#
# Multi-project safe: each project's instances are isolated by name.
# Per-project log/state dirs: /var/log/dev-studio/<project>/...
#
# Idempotent. Safe to re-run.
# Per ADR-0010.
#
# Env vars:
#   PROJECT_NAME            override project name (default: basename of repo root)
#   REPO_ROOT               override repo root (default: auto-detect)
#   INSTALL_ENABLE_LINGER=1 try to enable loginctl linger (asks sudo)
#   MIGRATE_LEGACY=skip     don't auto-disable legacy single-instance watchers (default: disable)

set -euo pipefail

# Auto-detect repo root from script location, allow override via env
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PROJECT_NAME="${PROJECT_NAME:-$(basename "$REPO_ROOT")}"
ROLES=(orchestrator product-manager architect developer tester)
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
INSTANCES_DIR="$HOME/.config/dev-studio/instances"
SRC_UNITS="$REPO_ROOT/scripts/install/systemd"
HEARTBEAT_BASE="${DEV_STUDIO_HEARTBEAT_BASE:-/var/log/dev-studio}"
PROJECT_HEARTBEAT_DIR="$HEARTBEAT_BASE/$PROJECT_NAME"

# --- color/output ---------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"; C_RED="$(tput setaf 1)"
  C_BOLD="$(tput bold)"; C_RESET="$(tput sgr0)"
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; C_RESET=""
fi
log()  { printf '%s[install]%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
ok()   { printf '%s[install]%s %s%s%s\n' "$C_BOLD" "$C_RESET" "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s[install]%s %s%s%s\n' "$C_BOLD" "$C_RESET" "$C_YELLOW" "$*" "$C_RESET"; }
fail() { printf '%s[install]%s %s%s%s\n' "$C_BOLD" "$C_RESET" "$C_RED" "$*" "$C_RESET"; exit 1; }

# --- preflight ------------------------------------------------------------
log "preflight checks for project: $PROJECT_NAME"
log "  repo root: $REPO_ROOT"
log "  heartbeat: $PROJECT_HEARTBEAT_DIR"

[ -d "$REPO_ROOT" ] || fail "REPO_ROOT not found: $REPO_ROOT"
[ -d "$SRC_UNITS" ] || fail "unit source dir not found: $SRC_UNITS"
# project name sanity: alphanumeric + - + _
[[ "$PROJECT_NAME" =~ ^[A-Za-z0-9_-]+$ ]] \
  || fail "PROJECT_NAME contains illegal chars (allowed: alnum, dash, underscore): $PROJECT_NAME"
# rule out '--' in project name (we use '--' as project/role separator)
[[ "$PROJECT_NAME" != *"--"* ]] \
  || fail "PROJECT_NAME must not contain '--' (used as separator): $PROJECT_NAME"

# Detect un-rendered template state and guide the user toward dev-studio-init.sh
if [ -f "$SRC_UNITS/dev-studio-watcher@.service.tmpl" ] && \
   [ ! -f "$SRC_UNITS/dev-studio-watcher@.service" ]; then
  fail "systemd units not rendered yet. Run: bash $REPO_ROOT/scripts/dev-studio-init.sh first."
fi

[ -f "$SRC_UNITS/dev-studio-watcher@.service" ] || fail "watcher unit template missing (run dev-studio-init.sh)"
command -v systemctl >/dev/null 2>&1 || fail "systemctl not found"
systemctl --user --no-pager show-environment >/dev/null 2>&1 \
  || fail "systemd --user not available (no XDG_RUNTIME_DIR session bus)"
mkdir -p "$SYSTEMD_USER_DIR" "$INSTANCES_DIR" 2>/dev/null || true
# Per-project heartbeat dir (sudo only if parent doesn't exist or is unwritable)
if [ ! -d "$PROJECT_HEARTBEAT_DIR" ]; then
  if ! mkdir -p "$PROJECT_HEARTBEAT_DIR" 2>/dev/null; then
    log "creating $PROJECT_HEARTBEAT_DIR with sudo"
    sudo mkdir -p "$PROJECT_HEARTBEAT_DIR"
    sudo chown "$USER:$USER" "$PROJECT_HEARTBEAT_DIR"
    sudo chmod 755 "$PROJECT_HEARTBEAT_DIR"
  fi
fi
mkdir -p "$PROJECT_HEARTBEAT_DIR/agent-state" 2>/dev/null || true
ok "preflight passed"

# --- stage: legacy migration (single-instance watchers from before ADR-0010) -
log "checking for legacy single-instance watchers (pre-ADR-0010)"
LEGACY_FOUND=0
LEGACY_DISABLED=()
for role in "${ROLES[@]}"; do
  legacy_unit="dev-studio-watcher@${role}.service"
  if systemctl --user is-enabled "$legacy_unit" >/dev/null 2>&1; then
    LEGACY_FOUND=1
    if [ "${MIGRATE_LEGACY:-disable}" = "skip" ]; then
      warn "legacy $legacy_unit still enabled (MIGRATE_LEGACY=skip)"
    else
      log "  disabling legacy $legacy_unit"
      systemctl --user disable --now "$legacy_unit" >/dev/null 2>&1 || true
      LEGACY_DISABLED+=("$legacy_unit")
    fi
  fi
done
# legacy reload .path
if systemctl --user is-enabled dev-studio-watcher-reload.path >/dev/null 2>&1; then
  LEGACY_FOUND=1
  if [ "${MIGRATE_LEGACY:-disable}" = "skip" ]; then
    warn "legacy dev-studio-watcher-reload.path still enabled"
  else
    log "  disabling legacy dev-studio-watcher-reload.path"
    systemctl --user disable --now dev-studio-watcher-reload.path >/dev/null 2>&1 || true
    LEGACY_DISABLED+=("dev-studio-watcher-reload.path")
  fi
fi
if [ ${#LEGACY_DISABLED[@]} -gt 0 ]; then
  ok "legacy disabled: ${LEGACY_DISABLED[*]}"
  warn "  if you still need them for another project, re-install from THAT project:"
  warn "    cd <other-project> && bash scripts/install/dev-studio-install-systemd.sh"
elif [ $LEGACY_FOUND -eq 0 ]; then
  ok "no legacy single-instance watchers found"
fi

# --- stage: stop any stray nohup watchers --------------------------------
log "checking for stray nohup agent-watch.sh processes"
if pgrep -af "agent-watch.sh.*--loop" >/dev/null 2>&1; then
  STRAY_PIDS="$(pgrep -af "agent-watch.sh.*--loop" | awk '{print $1}' | tr '\n' ' ')"
  warn "stray watcher PIDs: $STRAY_PIDS"
  warn "  (these will be replaced by systemd-managed instances; killing them)"
  pkill -f "agent-watch.sh.*--loop" || true
  sleep 2
  if pgrep -af "agent-watch.sh.*--loop" >/dev/null 2>&1; then
    pkill -9 -f "agent-watch.sh.*--loop" || true
    sleep 1
  fi
  ok "stray watchers stopped"
else
  ok "no stray nohup watchers"
fi

# --- stage: write generic watcher template --------------------------------
log "installing generic watcher unit template"
cp -f "$SRC_UNITS/dev-studio-watcher@.service" "$SYSTEMD_USER_DIR/"

# --- stage: write per-instance env files ----------------------------------
log "writing per-instance env files to $INSTANCES_DIR"
for role in "${ROLES[@]}"; do
  instance="${PROJECT_NAME}--${role}"
  env_file="$INSTANCES_DIR/${instance}.env"
  cat > "$env_file" <<ENV
# Generated by dev-studio-install-systemd.sh
# Project: $PROJECT_NAME
# Role: $role
REPO_ROOT=$REPO_ROOT
ROLE=$role
PROJECT=$PROJECT_NAME
DEV_STUDIO_HEARTBEAT_DIR=$PROJECT_HEARTBEAT_DIR
AGENT_STATE_DIR=$PROJECT_HEARTBEAT_DIR/agent-state
ENV
  chmod 644 "$env_file"
done
ok "5 env files written"

# --- stage: write per-instance drop-in overrides (ADR-0011) ----------------
# systemd EnvironmentFile= variables are ONLY expanded inside ExecStart=
# (and ExecStop/ExecReload). Settings like WorkingDirectory= and
# StandardOutput=append:PATH require ABSOLUTE paths at unit-parse time —
# they will NOT expand ${REPO_ROOT} from EnvironmentFile.
#
# Therefore each instance gets a drop-in override.conf with rendered
# absolute paths. The base template (dev-studio-watcher@.service)
# intentionally omits these settings; the drop-in supplies them.
log "writing per-instance drop-in overrides (ADR-0011)"
for role in "${ROLES[@]}"; do
  instance="${PROJECT_NAME}--${role}"
  dropin_dir="$SYSTEMD_USER_DIR/dev-studio-watcher@${instance}.service.d"
  dropin_file="$dropin_dir/override.conf"
  mkdir -p "$dropin_dir"
  log_file="$PROJECT_HEARTBEAT_DIR/${role}.watch.log"
  cat > "$dropin_file" <<DROPIN
# Generated by dev-studio-install-systemd.sh — DO NOT EDIT by hand.
# Re-run the installer to regenerate, or use \`systemctl --user edit
# dev-studio-watcher@${instance}\` for additional per-instance tweaks
# (they'll go into a separate override file and survive re-installs).
#
# These absolute paths cannot live in the base template because systemd
# does not expand EnvironmentFile vars inside WorkingDirectory= or
# StandardOutput=. See ADR-0011 for rationale.
#
# Project : $PROJECT_NAME
# Role    : $role
# Repo    : $REPO_ROOT
[Service]
WorkingDirectory=$REPO_ROOT
# Reset ExecStart= first (drop-ins are additive otherwise), then set ours.
ExecStart=
ExecStart=/usr/bin/bash $REPO_ROOT/scripts/agent-watch.sh $role --loop
StandardOutput=append:$log_file
StandardError=append:$log_file
DROPIN
  chmod 644 "$dropin_file"
done
ok "5 drop-in overrides written under $SYSTEMD_USER_DIR/dev-studio-watcher@<inst>.service.d/"

# --- stage: write per-project reload .path + .service ---------------------
# These can't use env expansion (systemd .path doesn't support EnvironmentFile),
# so we render them per-project with hardcoded paths.
log "writing per-project reload units"
RELOAD_PATH_UNIT="$SYSTEMD_USER_DIR/dev-studio-watcher-reload-${PROJECT_NAME}.path"
RELOAD_SVC_UNIT="$SYSTEMD_USER_DIR/dev-studio-watcher-reload-${PROJECT_NAME}.service"
WATCHER_RESTART_LIST=""
for role in "${ROLES[@]}"; do
  WATCHER_RESTART_LIST+=" dev-studio-watcher@${PROJECT_NAME}--${role}.service"
done
# Trim leading space
WATCHER_RESTART_LIST="${WATCHER_RESTART_LIST# }"

cat > "$RELOAD_PATH_UNIT" <<PATHUNIT
[Unit]
Description=Watch $PROJECT_NAME agent-watch.sh for changes and reload its 5 watchers
Documentation=https://github.com/{{GITHUB_OWNER}}/{{GITHUB_REPO}}/blob/main/docs/decisions/ADR-0010-per-project-watchers.md
# Debounce
StartLimitIntervalSec=30
StartLimitBurst=2

[Path]
PathChanged=$REPO_ROOT/scripts/agent-watch.sh
Unit=dev-studio-watcher-reload-${PROJECT_NAME}.service

[Install]
WantedBy=default.target
PATHUNIT

cat > "$RELOAD_SVC_UNIT" <<SVCUNIT
[Unit]
Description=Restart $PROJECT_NAME dev-studio watchers (agent-watch.sh changed)
Documentation=https://github.com/{{GITHUB_OWNER}}/{{GITHUB_REPO}}/blob/main/docs/decisions/ADR-0010-per-project-watchers.md

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/systemctl --user restart $WATCHER_RESTART_LIST
ExecStartPost=/bin/sh -c 'echo "[watcher-reload:$PROJECT_NAME] \$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ) restarted 5 watchers" >> $PROJECT_HEARTBEAT_DIR/watcher-reload.log'
SVCUNIT
ok "reload units written"

systemctl --user daemon-reload
ok "daemon reloaded"

# --- stage: enable + start per role --------------------------------------
log "enabling and starting watcher units (5 roles) for $PROJECT_NAME"
for role in "${ROLES[@]}"; do
  instance="${PROJECT_NAME}--${role}"
  unit="dev-studio-watcher@${instance}.service"
  systemctl --user enable --now "$unit" >/dev/null 2>&1 || true
  if systemctl --user is-active "$unit" >/dev/null 2>&1; then
    ok "  $role -> active ($unit)"
  else
    warn "  $role -> NOT active (check: journalctl --user -u $unit -n 50)"
  fi
done

# --- stage: enable auto-reload path --------------------------------------
log "enabling per-project auto-reload path"
systemctl --user enable --now "dev-studio-watcher-reload-${PROJECT_NAME}.path" >/dev/null 2>&1 || true
if systemctl --user is-active "dev-studio-watcher-reload-${PROJECT_NAME}.path" >/dev/null 2>&1; then
  ok "auto-reload path -> active (changes to $REPO_ROOT/scripts/agent-watch.sh trigger restart)"
else
  warn "auto-reload path -> NOT active"
fi

# --- linger (optional, asks operator) ------------------------------------
log "checking linger (controls watcher start on VM boot before login)"
if loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
  ok "linger already enabled; watchers will start on VM boot"
else
  warn "linger is OFF — watchers won't start until you SSH in after a reboot"
  if [ "${INSTALL_ENABLE_LINGER:-}" = "1" ]; then
    log "INSTALL_ENABLE_LINGER=1 set; attempting sudo loginctl enable-linger $USER"
    if sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
      ok "linger enabled"
    else
      warn "sudo failed; run manually: sudo loginctl enable-linger $USER"
    fi
  else
    echo "         To enable boot-time start (recommended):"
    echo "           sudo loginctl enable-linger $USER"
    echo "         Or re-run with: INSTALL_ENABLE_LINGER=1 bash $0"
  fi
fi

# --- final summary --------------------------------------------------------
echo
log "summary for project: $PROJECT_NAME"
systemctl --user --no-pager --type=service \
  list-units "dev-studio-watcher@${PROJECT_NAME}--*" 2>/dev/null || true
echo
systemctl --user --no-pager --type=path \
  list-units "dev-studio-watcher-reload-${PROJECT_NAME}.path" 2>/dev/null || true
echo
ok "install complete. Next steps:"
echo "  - Verify a role:    systemctl --user status dev-studio-watcher@${PROJECT_NAME}--developer"
echo "  - Tail a log:       tail -f $PROJECT_HEARTBEAT_DIR/developer.watch.log"
echo "  - Test auto-reload: touch $REPO_ROOT/scripts/agent-watch.sh"
echo "                      systemctl --user show -p ActiveEnterTimestamp dev-studio-watcher@${PROJECT_NAME}--developer"
echo "  - Kick a role:      bash $REPO_ROOT/scripts/agent-doctor.sh --kick developer"
echo "  - Uninstall:        bash $REPO_ROOT/scripts/install/dev-studio-uninstall-systemd.sh"
