#!/usr/bin/env bash
# dev-studio-start.sh — Launch the 6-pane tmux session for dev studio
#
# Layout (3 rows x 2 cols):
#   Pane 0: ORCHESTRATOR   | Pane 1: PRODUCT MANAGER
#   Pane 2: ARCHITECT      | Pane 3: DEVELOPER
#   Pane 4: TESTER         | Pane 5: HUMAN
#
# Each agent pane:
#   - cd to repo root
#   - source environment
#   - touch heartbeat file
#   - print banner; manual `claude` launch
#
# Human pane: plain bash for git/log/manual commands.
#
# Usage:
#   ./scripts/dev-studio-start.sh         # start (creates or replaces session)
#   ./scripts/dev-studio-start.sh attach  # only attach to existing
#   ./scripts/dev-studio-start.sh stop    # kill the session

set -euo pipefail

SESSION="dev-studio"
# Auto-detect repo root from script location, allow override via env
# (kept overridable for tests / CI / non-standard layouts)
REPO_ROOT="${DEV_STUDIO_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Per-project heartbeat dir (ADR-0010). Default: /var/log/dev-studio/<project>/
PROJECT_NAME="${DEV_STUDIO_PROJECT_NAME:-$(basename "$REPO_ROOT")}"
HEARTBEAT_BASE="${DEV_STUDIO_HEARTBEAT_BASE:-/var/log/dev-studio}"
HEARTBEAT_DIR="${DEV_STUDIO_HEARTBEAT_DIR:-$HEARTBEAT_BASE/$PROJECT_NAME}"
ENV_FILE="$HOME/.dev-studio-env"
BOOT_DIR="$REPO_ROOT/scripts/.tmux-bootstrap"

# --- Helpers ---
have_session() {
  tmux has-session -t "$SESSION" 2>/dev/null
}

ensure_heartbeat_dir() {
  if [[ ! -d "$HEARTBEAT_DIR" ]]; then
    sudo mkdir -p "$HEARTBEAT_DIR"
    sudo chown "$USER:$USER" "$HEARTBEAT_DIR"
    sudo chmod 755 "$HEARTBEAT_DIR"
  fi
}

# Write a bootstrap shell file for an agent role.
#
# Pane lifecycle has two modes (resolved at pane start, not at write-time):
#
#   - **systemd mode** (ADR-0006, preferred): the watcher is managed by
#     dev-studio-watcher@<role>.service. The pane does NOT spawn a watcher,
#     does NOT install a cleanup trap, and merely reports the unit status
#     in the banner. Watcher lives across pane/claude lifecycle.
#
#   - **nohup fallback mode** (legacy, used when units are not installed):
#     the pane spawns agent-watch.sh --loop in the background, writes a
#     PID file, and kills the watcher when claude exits. This was the
#     pre-D4 default and is retained so the script still works on hosts
#     where dev-studio-install-systemd.sh has not been run.
#
# Mode detection is `systemctl --user is-enabled dev-studio-watcher@<role>`,
# done at pane bootstrap time so a fresh `install` doesn't require re-running
# this script.
write_agent_bootstrap() {
  local role="$1"
  local file="$BOOT_DIR/${role}.sh"
  local role_upper
  role_upper="$(echo "$role" | tr '[:lower:]' '[:upper:]')"
  cat > "$file" <<EOF
#!/usr/bin/env bash
# Her pane KENDİ title'ını set eder — tmux pane-index reassignment'ından bağımsız.
[ -n "\$TMUX_PANE" ] && tmux select-pane -t "\$TMUX_PANE" -T "${role_upper}"
cd "$REPO_ROOT"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
touch "$HEARTBEAT_DIR/${role}.heartbeat"

WATCH_LOG="$HEARTBEAT_DIR/${role}.watch.log"
WATCH_UNIT="dev-studio-watcher@${PROJECT_NAME}--${role}.service"

# --- watcher mode detection (ADR-0010) ---
WATCHER_MODE="nohup"
if systemctl --user is-enabled "\$WATCH_UNIT" >/dev/null 2>&1; then
  WATCHER_MODE="systemd"
fi

if [ "\$WATCHER_MODE" = "systemd" ]; then
  # --- systemd mode: watcher is managed externally ---
  # Ensure unit is running (idempotent); no PID file, no trap.
  systemctl --user start "\$WATCH_UNIT" 2>/dev/null || true
  WATCH_PID="\$(systemctl --user show -p MainPID --value "\$WATCH_UNIT" 2>/dev/null)"
  WATCH_STATUS_LINE="  Watcher: \$WATCH_UNIT (PID \$WATCH_PID) — systemd-managed"
else
  # --- nohup fallback mode (pre-D4 behaviour) ---
  WATCH_PID_FILE="$HEARTBEAT_DIR/${role}.watch.pid"

  # Kill any stale watcher from a previous session.
  if [ -f "\$WATCH_PID_FILE" ]; then
    OLD_PID="\$(cat "\$WATCH_PID_FILE" 2>/dev/null || true)"
    if [ -n "\$OLD_PID" ] && kill -0 "\$OLD_PID" 2>/dev/null; then
      kill "\$OLD_PID" 2>/dev/null || true
    fi
    rm -f "\$WATCH_PID_FILE"
  fi

  # Start the watcher in the background.
  nohup bash "$REPO_ROOT/scripts/agent-watch.sh" "${role}" --loop \\
    > "\$WATCH_LOG" 2>&1 &
  echo \$! > "\$WATCH_PID_FILE"
  WATCH_PID="\$(cat "\$WATCH_PID_FILE")"

  # Cleanup hook: when this bootstrap exits (claude quits or pane closes),
  # stop the background watcher so we don't leak daemons.
  cleanup_watcher() {
    if [ -n "\$WATCH_PID" ] && kill -0 "\$WATCH_PID" 2>/dev/null; then
      kill "\$WATCH_PID" 2>/dev/null || true
    fi
    rm -f "\$WATCH_PID_FILE"
  }
  trap cleanup_watcher EXIT INT TERM
  WATCH_STATUS_LINE="  Watcher: PID \$WATCH_PID (nohup; install systemd units for resilience)"
fi

clear
echo "═══════════════════════════════════════════════════════════"
echo "  ${role_upper}"
echo "  Repo: $REPO_ROOT"
echo "  Soul: .claude/agents/${role}.md"
echo "  Heartbeat: $HEARTBEAT_DIR/${role}.heartbeat"
echo "\$WATCH_STATUS_LINE"
echo "  Log: \$WATCH_LOG"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Claude Code otomatik başlatılıyor (--dangerously-skip-permissions)"
echo "Soul: .claude/agents/${role}.md zaten diskte, bellekte yüklenecek"
echo "Self-driving loop aktif: 60s'de bir GitHub poll, event çıkarsa pane uyanır."
echo ""

# Claude exit edince trap cleanup'ı çalıştırır. Sonra fallback bash.

KICKOFF_FILE="$REPO_ROOT/scripts/kickoff/${role}.txt"
if [ -f "\$KICKOFF_FILE" ]; then
  KICKOFF_PROMPT="\$(cat "\$KICKOFF_FILE")"
else
  KICKOFF_PROMPT="Read .claude/agents/${role}.md and CLAUDE.md. Check $HEARTBEAT_DIR/agent-state/${role}.json for pending events. Act on events or wait for next watcher poll."
fi

claude --dangerously-skip-permissions --agent "${role}" --append-system-prompt-file "$REPO_ROOT/.claude/agents/${role}.md" "\$KICKOFF_PROMPT"

exec bash
EOF
  chmod +x "$file"
}

write_human_bootstrap() {
  local file="$BOOT_DIR/human.sh"
  cat > "$file" <<EOF
#!/usr/bin/env bash
# Her pane KENDİ title'ını set eder.
[ -n "\$TMUX_PANE" ] && tmux select-pane -t "\$TMUX_PANE" -T "HUMAN"
cd "$REPO_ROOT"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
clear
echo "═══════════════════════════════════════════════════════════"
echo "  HUMAN (atil can)"
echo "  Repo: $REPO_ROOT"
echo "  Use this pane for git, logs, manual commands"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Hızlı komutlar:"
echo "  git status"
echo "  systemctl status dev-studio-health.timer"
echo "  journalctl -u dev-studio-health.service -f"
echo "  scripts/notify.sh -l info 'test'"
EOF
  chmod +x "$file"
}

# --- Actions ---
case "${1:-start}" in
  attach)
    have_session || { echo "Session '$SESSION' yok, önce '$0' çalıştır"; exit 1; }
    tmux attach -t "$SESSION"
    exit 0
    ;;
  stop)
    if have_session; then
      tmux kill-session -t "$SESSION"
      echo "Session '$SESSION' kapatıldı"
    else
      echo "Session '$SESSION' zaten yok"
    fi
    exit 0
    ;;
  start) ;;
  *)
    echo "Usage: $0 {start|attach|stop}" >&2
    exit 1
    ;;
esac

# --- Start (idempotent: kill existing first) ---
ensure_heartbeat_dir
mkdir -p "$BOOT_DIR"

if have_session; then
  echo "Mevcut session bulundu, kapatılıyor..."
  tmux kill-session -t "$SESSION"
fi

echo "Bootstrap dosyaları yazılıyor..."
for role in orchestrator product-manager architect developer tester; do
  write_agent_bootstrap "$role"
done
write_human_bootstrap

echo "Yeni session '$SESSION' başlatılıyor..."

# KRITIK: Detached session'a büyük virtual size ver (default 80x24 6 pane'e yetmez).
# Her split sonrası 'tiled' layout uygula — aksi halde split-window 'no space' hatası verir.

# Pane 0: Orchestrator (initial pane of the session)
tmux new-session -d -s "$SESSION" -n main -x 240 -y 60 \
  "bash --rcfile <(echo 'source $BOOT_DIR/orchestrator.sh')"

# Pane 1: Product Manager
tmux split-window -h -t "$SESSION:main" \
  "bash --rcfile <(echo 'source $BOOT_DIR/product-manager.sh')"
tmux select-layout -t "$SESSION:main" tiled

# Pane 2: Architect
tmux split-window -v -t "$SESSION:main" \
  "bash --rcfile <(echo 'source $BOOT_DIR/architect.sh')"
tmux select-layout -t "$SESSION:main" tiled

# Pane 3: Developer
tmux split-window -v -t "$SESSION:main" \
  "bash --rcfile <(echo 'source $BOOT_DIR/developer.sh')"
tmux select-layout -t "$SESSION:main" tiled

# Pane 4: Tester
tmux split-window -v -t "$SESSION:main" \
  "bash --rcfile <(echo 'source $BOOT_DIR/tester.sh')"
tmux select-layout -t "$SESSION:main" tiled

# Pane 5: Human
tmux split-window -v -t "$SESSION:main" \
  "bash --rcfile <(echo 'source $BOOT_DIR/human.sh')"
tmux select-layout -t "$SESSION:main" tiled

# Pane border + title display
# Title'ı her bootstrap script kendisi set eder (tmux select-pane -T içeride).
# Bu yüzden launcher tarafında hardcoded index → title eşlemesi YOK.
tmux set -t "$SESSION" pane-border-status top
tmux set -t "$SESSION" pane-border-format " #{pane_index}: #{pane_title} "

# Status bar styling
tmux set -t "$SESSION" status-style "bg=colour236,fg=colour250"
tmux set -t "$SESSION" status-left "#[bg=colour33,fg=white,bold] dev-studio #[default] "
tmux set -t "$SESSION" status-right "#[fg=colour245]%H:%M | #(hostname) "
tmux set -t "$SESSION" status-interval 5

# Focus on human pane (5) by default
tmux select-pane -t "$SESSION:main.5"

echo ""
echo "Session hazır. Bağlanmak için:"
echo "  tmux attach -t $SESSION"
echo "Veya: $0 attach"
