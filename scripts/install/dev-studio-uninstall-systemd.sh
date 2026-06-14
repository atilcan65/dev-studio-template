#!/usr/bin/env bash
# dev-studio-uninstall-systemd.sh — remove per-project watchers
#
# Removes:
#   - 5 systemd --user watcher instances for this project
#   - per-project reload .path + .service
#   - per-instance env files
#
# By default does NOT remove:
#   - generic dev-studio-watcher@.service template (other projects may use it)
#   - $HEARTBEAT_DIR (logs preserved)
#
# Use --purge to also remove generic template + heartbeat dir.
#
# Per ADR-0010.

set -euo pipefail

PROJECT_NAME=""
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --project=*) PROJECT_NAME="${arg#--project=}" ;;
    --project)   shift; PROJECT_NAME="${1:-}" ;;
    --purge)     PURGE=1 ;;
    -h|--help)
      cat <<HELP
Usage: $0 [--project NAME] [--purge]
  --project NAME   Project to uninstall (default: basename of repo root)
  --purge          Also remove generic template + heartbeat dir
HELP
      exit 0
      ;;
  esac
done

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PROJECT_NAME="${PROJECT_NAME:-$(basename "$REPO_ROOT")}"
ROLES=(orchestrator product-manager architect developer tester)
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
INSTANCES_DIR="$HOME/.config/dev-studio/instances"
HEARTBEAT_BASE="${DEV_STUDIO_HEARTBEAT_BASE:-/var/log/dev-studio}"
PROJECT_HEARTBEAT_DIR="$HEARTBEAT_BASE/$PROJECT_NAME"

# --- color/output ---------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"; C_RED="$(tput setaf 1)"
  C_BOLD="$(tput bold)"; C_RESET="$(tput sgr0)"
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; C_RESET=""
fi
log()  { printf '%s[uninstall]%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
ok()   { printf '%s[uninstall]%s %s%s%s\n' "$C_BOLD" "$C_RESET" "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s[uninstall]%s %s%s%s\n' "$C_BOLD" "$C_RESET" "$C_YELLOW" "$*" "$C_RESET"; }

log "uninstalling watchers for project: $PROJECT_NAME"

# --- stop + disable watcher instances ------------------------------------
for role in "${ROLES[@]}"; do
  instance="${PROJECT_NAME}--${role}"
  unit="dev-studio-watcher@${instance}.service"
  if systemctl --user is-enabled "$unit" >/dev/null 2>&1 \
     || systemctl --user is-active "$unit" >/dev/null 2>&1; then
    systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
    ok "disabled $unit"
  fi
done

# --- stop + disable per-project reload -----------------------------------
for u in "dev-studio-watcher-reload-${PROJECT_NAME}.path" "dev-studio-watcher-reload-${PROJECT_NAME}.service"; do
  if systemctl --user is-enabled "$u" >/dev/null 2>&1 \
     || systemctl --user is-active "$u" >/dev/null 2>&1; then
    systemctl --user disable --now "$u" >/dev/null 2>&1 || true
    ok "disabled $u"
  fi
done

# --- remove unit files --------------------------------------------------
rm -f "$SYSTEMD_USER_DIR/dev-studio-watcher-reload-${PROJECT_NAME}.path"
rm -f "$SYSTEMD_USER_DIR/dev-studio-watcher-reload-${PROJECT_NAME}.service"
ok "removed per-project reload unit files"

# --- remove per-instance env files --------------------------------------
for role in "${ROLES[@]}"; do
  instance="${PROJECT_NAME}--${role}"
  rm -f "$INSTANCES_DIR/${instance}.env"
done
ok "removed per-instance env files"

# --- purge mode -----------------------------------------------------------
if [ "$PURGE" = "1" ]; then
  log "PURGE mode: removing generic template + heartbeat dir"
  rm -f "$SYSTEMD_USER_DIR/dev-studio-watcher@.service"
  if [ -d "$PROJECT_HEARTBEAT_DIR" ]; then
    rm -rf "$PROJECT_HEARTBEAT_DIR" || warn "could not remove $PROJECT_HEARTBEAT_DIR (try sudo)"
  fi
  ok "purged"
fi

systemctl --user daemon-reload
ok "daemon reloaded"

# --- check for other projects sharing generic template ------------------
log "checking for other projects' watchers (informational)"
other=$(systemctl --user list-unit-files 'dev-studio-watcher@*.service' 2>/dev/null \
  | awk '/dev-studio-watcher@/ {print $1}' \
  | grep -v "@${PROJECT_NAME}--" \
  | grep -v '^dev-studio-watcher@\.service$' || true)
if [ -n "$other" ]; then
  warn "other projects still installed:"
  echo "$other" | sed 's/^/    /'
  warn "  --purge skipped (generic template kept for them)"
fi

echo
ok "uninstall complete for project: $PROJECT_NAME"
echo "  Heartbeat logs preserved at: $PROJECT_HEARTBEAT_DIR (use --purge to remove)"
