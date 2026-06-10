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
REPO_ROOT="/opt/dev-studio/atilprojects"
HEARTBEAT_DIR="/var/log/dev-studio"
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
# Pane will run: bash <bootstrap-file>; exec bash
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
clear
echo "═══════════════════════════════════════════════════════════"
echo "  ${role_upper}"
echo "  Repo: $REPO_ROOT"
echo "  Soul: .claude/agents/${role}.md"
echo "  Heartbeat: $HEARTBEAT_DIR/${role}.heartbeat"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Claude Code otomatik başlatılıyor (--dangerously-skip-permissions)"
echo "Soul: .claude/agents/${role}.md zaten diskte, bellekte yüklenecek"
echo ""
exec claude --dangerously-skip-permissions
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
