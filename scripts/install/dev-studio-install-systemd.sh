#!/usr/bin/env bash
# dev-studio-install-systemd.sh — one-shot installer for watcher resilience
#
# Idempotent. Run once per VM. Safe to re-run:
#   - Unit files are overwritten with the canonical copy from the repo
#   - daemon-reload is harmless
#   - enable --now is no-op if already enabled+running
#   - legacy nohup watchers are killed cleanly before systemd takes over
#
# After this script succeeds, future `git pull` events automatically restart all
# 5 watchers via dev-studio-watcher-reload.path. No more manual pkill+nohup.
#
# Requirements:
#   - systemd --user available (any modern Debian/Ubuntu/RHEL/Arch)
#   - User can run `systemctl --user` (true unless container/jailshell)
#   - Optional: sudo access for `loginctl enable-linger` (boot-time start)
#
# Per ADR-0006.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/opt/dev-studio/atilprojects}"
ROLES=(orchestrator product-manager architect developer tester)
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SRC_UNITS="$REPO_ROOT/scripts/install/systemd"

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
log "preflight checks"
[ -d "$REPO_ROOT" ] || fail "REPO_ROOT not found: $REPO_ROOT"
[ -d "$SRC_UNITS" ] || fail "unit source dir not found: $SRC_UNITS"
[ -f "$SRC_UNITS/dev-studio-watcher@.service" ] || fail "unit template missing"
[ -f "$SRC_UNITS/dev-studio-watcher-reload.path" ] || fail "reload .path missing"
[ -f "$SRC_UNITS/dev-studio-watcher-reload.service" ] || fail "reload .service missing"
command -v systemctl >/dev/null 2>&1 || fail "systemctl not found"
systemctl --user --no-pager show-environment >/dev/null 2>&1 \
  || fail "systemd --user not available (no XDG_RUNTIME_DIR session bus)"
mkdir -p "$SYSTEMD_USER_DIR" /var/log/dev-studio 2>/dev/null || true
ok "preflight passed"

# --- stage: write unit files ---------------------------------------------
log "installing unit files to $SYSTEMD_USER_DIR"
cp -f "$SRC_UNITS/dev-studio-watcher@.service"        "$SYSTEMD_USER_DIR/"
cp -f "$SRC_UNITS/dev-studio-watcher-reload.path"     "$SYSTEMD_USER_DIR/"
cp -f "$SRC_UNITS/dev-studio-watcher-reload.service"  "$SYSTEMD_USER_DIR/"
systemctl --user daemon-reload
ok "unit files in place + daemon reloaded"

# --- stage: stop legacy nohup watchers -----------------------------------
log "checking for legacy nohup watchers"
if pgrep -af "agent-watch.sh" >/dev/null 2>&1; then
  warn "legacy nohup watchers detected; killing them so systemd can take over"
  pgrep -af "agent-watch.sh" || true
  pkill -f "agent-watch.sh" || true
  sleep 2
  if pgrep -af "agent-watch.sh" >/dev/null 2>&1; then
    warn "some watchers still alive, sending SIGKILL"
    pkill -9 -f "agent-watch.sh" || true
    sleep 1
  fi
  ok "legacy watchers stopped"
else
  ok "no legacy nohup watchers found"
fi

# --- stage: enable + start per role --------------------------------------
log "enabling and starting watcher units (5 roles)"
for role in "${ROLES[@]}"; do
  unit="dev-studio-watcher@${role}.service"
  systemctl --user enable --now "$unit"
  if systemctl --user is-active "$unit" >/dev/null 2>&1; then
    ok "$role -> active"
  else
    warn "$role -> NOT active (check: journalctl --user -u $unit)"
  fi
done

# --- stage: enable auto-reload path --------------------------------------
log "enabling watcher auto-reload path unit"
systemctl --user enable --now dev-studio-watcher-reload.path
if systemctl --user is-active dev-studio-watcher-reload.path >/dev/null 2>&1; then
  ok "auto-reload path -> active (agent-watch.sh changes will restart watchers)"
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
    echo "         To enable boot-time start (recommended for template-grade reuse):"
    echo "           sudo loginctl enable-linger $USER"
    echo "         Or re-run with: INSTALL_ENABLE_LINGER=1 bash $0"
  fi
fi

# --- final summary --------------------------------------------------------
echo
log "summary"
systemctl --user --no-pager --type=service \
  list-units 'dev-studio-watcher@*' 2>/dev/null || true
echo
systemctl --user --no-pager --type=path \
  list-units 'dev-studio-watcher-reload.path' 2>/dev/null || true
echo
ok "install complete. Next steps:"
echo "  - Verify a role:    systemctl --user status dev-studio-watcher@developer"
echo "  - Tail a log:       tail -f /var/log/dev-studio/developer.watch.log"
echo "  - Test auto-reload: touch $REPO_ROOT/scripts/agent-watch.sh"
echo "                      systemctl --user show -p ActiveEnterTimestamp dev-studio-watcher@developer"
echo "  - Kick a role:      bash $REPO_ROOT/scripts/agent-doctor.sh --kick developer"
