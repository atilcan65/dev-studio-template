#!/usr/bin/env bash
# agent-doctor.sh — one-command diagnosis for stuck agents (Event Model v2).
#
# Per ADR-0003: silent-failure must be impossible. This tool answers
# "why isn't <role> waking up?" in seconds, with no screenshot chain.
#
# Usage:
#   agent-doctor.sh                          # check all 5 roles, print health summary
#   agent-doctor.sh <role>                   # deep-dive one role
#   agent-doctor.sh <role> --kick <pattern>  # surgical dedup removal (e.g. --kick pr-review-26)
#   agent-doctor.sh <role> --restart         # restart watcher (ADR-0006: systemd if available)
#   agent-doctor.sh --units                  # systemd watcher unit status table
#   agent-doctor.sh --alert                  # cron-friendly: stale roles → Telegram warn, exit code
#   agent-doctor.sh --fanout <PR_NUM>        # ADR-0008: which roles wake for this merged PR?
#
# Examples:
#   ./agent-doctor.sh                        # quick health board
#   ./agent-doctor.sh tester                 # why tester not waking?
#   ./agent-doctor.sh tester --kick pr-review-26
#   ./agent-doctor.sh tester --restart       # cycle a stuck watcher
#   ./agent-doctor.sh --units                # one-glance unit health
#   ./agent-doctor.sh --alert                # in cron: */5 * * * *
#   ./agent-doctor.sh --fanout 42            # simulate label-conditional fanout for PR #42
#
# Exit codes:
#   0  — all roles fresh (or single role healthy)
#   1  — at least one role stale (--alert mode)
#   2  — usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_HELPER="$SCRIPT_DIR/agent-state.sh"
NOTIFY="$SCRIPT_DIR/notify.sh"
STATE_DIR="${AGENT_STATE_DIR:-/var/log/dev-studio/agent-state}"
LOG_DIR="${AGENT_LOG_DIR:-/var/log/dev-studio}"
STALE_SEC="${AGENT_HEARTBEAT_STALE_SEC:-300}"

ROLES=(orchestrator product-manager architect developer tester)

# --- systemd helpers (ADR-0006) ---
unit_for() { echo "dev-studio-watcher@${1}.service"; }

unit_enabled() {
  systemctl --user is-enabled "$(unit_for "$1")" >/dev/null 2>&1
}
unit_active() {
  systemctl --user is-active "$(unit_for "$1")" >/dev/null 2>&1
}
unit_pid() {
  systemctl --user show -p MainPID --value "$(unit_for "$1")" 2>/dev/null
}
unit_restart() {
  systemctl --user restart "$(unit_for "$1")"
}

# Colours (graceful on no-TTY)
if [ -t 1 ]; then
  G="\033[32m"; Y="\033[33m"; R="\033[31m"; B="\033[1m"; D="\033[0m"
else
  G=""; Y=""; R=""; B=""; D=""
fi

require_jq() {
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 127; }
}
require_jq

# --- repo detection (for cc:<role> checks) ---
REPO="${GITHUB_REPO:-}"
if [ -z "$REPO" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
fi

# --- per-role health check ---
# Prints one summary line. Returns 0 if fresh, 1 if stale.
role_health_line() {
  local role="$1"
  local state_file="${STATE_DIR}/${role}.json"
  local pid_file="${LOG_DIR}/${role}.watch.pid"

  if [ ! -f "$state_file" ]; then
    printf "  %-16s ${R}NO STATE${D}\n" "$role"
    return 1
  fi

  # PID alive? Prefer systemd (ADR-0006), fallback to pid file (legacy nohup).
  local pid pid_status="" src=""
  if unit_enabled "$role"; then
    src="sd"
    pid="$(unit_pid "$role")"
    if unit_active "$role" && [ -n "$pid" ] && [ "$pid" != "0" ] && kill -0 "$pid" 2>/dev/null; then
      pid_status="${G}sd pid=${pid}${D}"
    elif unit_active "$role"; then
      pid_status="${Y}sd active pid=?${D}"
    else
      pid_status="${R}sd INACTIVE${D}"
    fi
  elif [ -f "$pid_file" ]; then
    src="nohup"
    pid="$(cat "$pid_file")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      pid_status="${G}pid=${pid}${D}"
    else
      pid_status="${R}pid=${pid} DEAD${D}"
    fi
  else
    pid_status="${Y}no pid file${D}"
  fi

  # Heartbeat age
  local hb hb_epoch now_epoch age
  hb="$(jq -r '.last_heartbeat_utc // .last_seen_utc // empty' "$state_file")"
  if [ -z "$hb" ]; then
    printf "  %-16s ${R}NO HEARTBEAT${D}  %s\n" "$role" "$pid_status"
    return 1
  fi
  hb_epoch="$(date -u -d "$hb" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date -u +%s)"
  age=$((now_epoch - hb_epoch))

  local age_str hb_colour
  if [ "$age" -lt 120 ]; then
    age_str="${age}s"; hb_colour="$G"
  elif [ "$age" -lt "$STALE_SEC" ]; then
    age_str="${age}s"; hb_colour="$Y"
  else
    age_str="${age}s STALE"; hb_colour="$R"
  fi

  # Dedup list size
  local dedup_count
  dedup_count="$(jq '.processed_event_ids | length' "$state_file")"

  # cc:<role> PR count
  local cc_count="?"
  if [ -n "$REPO" ]; then
    cc_count="$(gh pr list --repo "$REPO" --label "cc:${role}" --state open --json number --jq 'length' 2>/dev/null || echo "?")"
  fi

  printf "  %-16s %s  hb=${hb_colour}%s${D}  dedup=%-3s  cc=%-2s\n" \
    "$role" "$pid_status" "$age_str" "$dedup_count" "$cc_count"

  [ "$age" -lt "$STALE_SEC" ]
}

# --- deep dive ---
role_deep_dive() {
  local role="$1"
  local state_file="${STATE_DIR}/${role}.json"
  local watch_log="${LOG_DIR}/${role}.watch.log"

  echo ""
  printf "${B}=== %s — deep dive ===${D}\n" "$role"
  echo ""

  if [ ! -f "$state_file" ]; then
    echo "  ✗ no state file at $state_file"
    return 1
  fi

  echo "  State file: $state_file"
  jq . "$state_file" | sed 's/^/    /'
  echo ""

  # Last 5 poll outcomes
  if [ -f "$watch_log" ]; then
    echo "  Last 5 poll outcomes (from $watch_log):"
    tail -n 500 "$watch_log" \
      | jq -c 'select(.role) | {at: .polled_at_utc, n: (.new_events | length), ids: [.new_events[].id]}' 2>/dev/null \
      | tail -n 5 | sed 's/^/    /'
    echo ""
  fi

  # cc:<role> PRs
  if [ -n "$REPO" ]; then
    echo "  Open PRs with cc:${role}:"
    gh pr list --repo "$REPO" --label "cc:${role}" --state open \
      --json number,title,updatedAt,headRefOid,labels 2>/dev/null \
      | jq -r '.[] | "    #\(.number) sha=\(.headRefOid[:7]) updated=\(.updatedAt) — \(.title)"' || echo "    (none)"
    echo ""
  fi

  # Diagnosis hints
  echo "  Diagnosis hints:"
  local dedup_size
  dedup_size="$(jq '.processed_event_ids | length' "$state_file")"
  if [ "$dedup_size" -gt 40 ]; then
    echo "    • dedup list at $dedup_size entries — close to trim limit (50); consider lowering."
  fi

  # Find PRs whose head_sha + cc combination is already deduped
  if [ -n "$REPO" ]; then
    local cc_prs
    cc_prs="$(gh pr list --repo "$REPO" --label "cc:${role}" --state open \
      --json number,headRefOid 2>/dev/null || echo '[]')"
    echo "$cc_prs" | jq -r '.[] | "\(.number) \(.headRefOid[:7])"' | while read -r num sha; do
      [ -z "$num" ] && continue
      # Does processed list contain a pr-review entry matching this number+sha?
      if jq -e --arg n "$num" --arg s "$sha" \
        '.processed_event_ids | any(. as $id | $id | test("pr-(review|commit)-" + $n + "-" + $s))' \
        "$state_file" >/dev/null 2>&1; then
        echo "    • PR #${num} (sha ${sha}) already in dedup — agent will not re-wake until SHA changes or label flip."
        echo "      Unblock with:  $0 $role --kick pr-review-${num}"
        echo "      Or:            $0 $role --kick pr-commit-${num}-${sha}"
      fi
    done
  fi
  echo ""
}

# --- alert mode (cron-friendly) ---
alert_mode() {
  local stale_roles=()
  for role in "${ROLES[@]}"; do
    if ! "$STATE_HELPER" stale "$role" "$STALE_SEC" >/dev/null 2>&1; then
      stale_roles+=("$role")
    fi
  done

  if [ "${#stale_roles[@]}" -eq 0 ]; then
    exit 0
  fi

  local msg="🩺 agent-doctor: ${#stale_roles[@]} role(s) stale (no heartbeat >${STALE_SEC}s): ${stale_roles[*]}
Run on VM:  /opt/dev-studio/atilprojects/scripts/agent-doctor.sh ${stale_roles[0]}"

  if [ -x "$NOTIFY" ]; then
    "$NOTIFY" -l warn "$msg" >/dev/null 2>&1 || true
  fi
  echo "$msg" >&2
  exit 1
}

# --- units mode (ADR-0006): one-glance systemd watcher table ---
units_mode() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not available"; exit 1
  fi
  printf "${B}agent-doctor --units (systemd watcher health)${D}\n\n"
  if ! systemctl --user --no-pager list-units 'dev-studio-watcher@*.service' 2>/dev/null | grep -q dev-studio-watcher; then
    echo "  No dev-studio-watcher units found."
    echo "  Install with:  bash $(cd "$SCRIPT_DIR" && pwd)/install/dev-studio-install-systemd.sh"
    exit 0
  fi
  printf "  %-18s %-9s %-9s %-8s %s\n" ROLE ENABLED ACTIVE PID UPTIME
  for role in "${ROLES[@]}"; do
    local u en act pid since
    u="$(unit_for "$role")"
    en="$(systemctl --user is-enabled "$u" 2>/dev/null || echo "-")"
    act="$(systemctl --user is-active  "$u" 2>/dev/null || echo "-")"
    pid="$(unit_pid "$role")"
    [ -z "$pid" ] && pid="-"
    since="$(systemctl --user show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || echo "-")"
    printf "  %-18s %-9s %-9s %-8s %s\n" "$role" "$en" "$act" "$pid" "$since"
  done
  echo ""
  if systemctl --user --no-pager is-active dev-studio-watcher-reload.path >/dev/null 2>&1; then
    printf "  reload-path:       ${G}active${D} (auto-restart on agent-watch.sh change)\n"
  else
    printf "  reload-path:       ${Y}inactive${D} — watcher won't auto-reload on git pull\n"
  fi
  echo ""
  echo "  Tip: ./agent-doctor.sh <role> --restart    — cycle one watcher"
  echo "       journalctl --user -u dev-studio-watcher@<role>  — systemd logs"
}

# --- fanout mode (ADR-0008): simulate label-conditional pr_merged fanout ---
# Given a PR number, fetch its labels and show — for each of the 5 roles —
# whether that role would wake on the merged event under the current
# PR_MERGED_FANOUT_DEFAULT / PR_MERGED_FANOUT_RULES_ENABLED config.
#
# Sources the same helper functions from agent-watch.sh, so the answer here is
# byte-for-byte the decision the watcher will make at poll time.
fanout_mode() {
  local pr_num="${1:-}"
  if [ -z "$pr_num" ] || ! [[ "$pr_num" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --fanout requires a numeric PR number (e.g. --fanout 42)" >&2
    exit 2
  fi
  if [ -z "$REPO" ]; then
    echo "ERROR: cannot determine repo (set GITHUB_REPO or run inside a gh-authenticated checkout)" >&2
    exit 2
  fi

  # Pull config + helpers from the watcher we ship alongside this doctor.
  # We only need the env defaults and the four role_* helper functions; sourcing
  # is gated to the helper block so we don't run the watcher's main loop.
  #
  # The helpers live in lines starting with the "v3.1 (ADR-0008)" marker; rather
  # than parse, we re-declare the defaults + functions here so doctor stays
  # standalone if agent-watch.sh ever moves. Behaviour MUST match the watcher
  # exactly (unit-tested at /tmp/d211-fanout-test.sh).
  # Issue #52 (BUG-1 sibling): empty string must disable the default fanout
  # (kill switch per ADR-0008 § 6). Using `${VAR-default}` (not `${VAR:-default}`)
  # so empty string is honored and only the unset case falls back to default.
  # Same fix as BUG-1 for PR_LABELED_FANOUT in PR #49 (commit 6823193).
  PR_MERGED_FANOUT_DEFAULT="${PR_MERGED_FANOUT_DEFAULT-orchestrator product-manager developer}"
  PR_MERGED_FANOUT_RULES_ENABLED="${PR_MERGED_FANOUT_RULES_ENABLED:-true}"

  role_in_default_fanout() {
    local r="$1"
    case " $PR_MERGED_FANOUT_DEFAULT " in
      *" $r "*) return 0 ;;
      *) return 1 ;;
    esac
  }
  role_eligible_via_label_rules() {
    [ "$PR_MERGED_FANOUT_RULES_ENABLED" = "true" ] || return 1
    case "$1" in
      architect|tester) return 0 ;;
      *) return 1 ;;
    esac
  }
  role_wakes_for_pr() {
    local r="$1" labels_json="$2"
    if role_in_default_fanout "$r"; then return 0; fi
    [ "$PR_MERGED_FANOUT_RULES_ENABLED" = "true" ] || return 1
    case "$r" in
      architect)
        echo "$labels_json" | jq -e 'any(.[]?; . == "needs-architect-review" or . == "agent:architect")' >/dev/null 2>&1 && return 0
        ;;
      tester)
        echo "$labels_json" | jq -e 'any(.[]?; . == "needs-tester-signoff" or . == "agent:tester")' >/dev/null 2>&1 && return 0
        ;;
    esac
    return 1
  }

  # Fetch PR metadata
  local pr_json
  pr_json="$(gh pr view "$pr_num" --repo "$REPO" \
    --json number,title,state,mergedAt,headRefOid,labels 2>/dev/null || true)"
  if [ -z "$pr_json" ] || [ "$pr_json" = "null" ]; then
    echo "ERROR: PR #${pr_num} not found in ${REPO}" >&2
    exit 2
  fi

  local title state merged_at sha labels_json
  title="$(echo "$pr_json"      | jq -r '.title')"
  state="$(echo "$pr_json"      | jq -r '.state')"
  merged_at="$(echo "$pr_json"  | jq -r '.mergedAt // "-"')"
  sha="$(echo "$pr_json"        | jq -r '.headRefOid[:7]')"
  labels_json="$(echo "$pr_json" | jq -c '[.labels[].name]')"
  # 'merged' field removed in gh 2.40+; derive from state + mergedAt.
  local merged="false"
  [ "$state" = "MERGED" ] && merged="true"

  printf "${B}agent-doctor --fanout (ADR-0008 pr_merged + ADR-0009 pr_labeled)${D}\n\n"
  printf "  PR #%s  sha=%s  state=%s  merged=%s\n" "$pr_num" "$sha" "$state" "$merged"
  printf "  Title:    %s\n" "$title"
  printf "  MergedAt: %s\n" "$merged_at"
  printf "  Labels:   %s\n\n" "$(echo "$labels_json" | jq -r 'if length == 0 then "(none)" else join(", ") end')"

  printf "  ${B}Config${D}\n"
  printf "    PR_MERGED_FANOUT_DEFAULT         = %s\n" "$(echo -n "$PR_MERGED_FANOUT_DEFAULT" | sed 's/^$/(empty — default fanout disabled)/')"
  printf "    PR_MERGED_FANOUT_RULES_ENABLED   = %s\n\n" "$PR_MERGED_FANOUT_RULES_ENABLED"

  printf "  ${B}Fanout decision${D}\n"
  printf "    %-16s %-6s %s\n" "ROLE" "WAKES" "REASON"
  local any_wakes=0
  for role in "${ROLES[@]}"; do
    local wakes reason
    if role_in_default_fanout "$role"; then
      wakes="yes"; reason="in PR_MERGED_FANOUT_DEFAULT"
    elif role_wakes_for_pr "$role" "$labels_json"; then
      wakes="yes"
      case "$role" in
        architect) reason="label rule: needs-architect-review or agent:architect" ;;
        tester)    reason="label rule: needs-tester-signoff or agent:tester" ;;
        *)         reason="label rule matched" ;;
      esac
    else
      wakes="no"
      if [ "$PR_MERGED_FANOUT_RULES_ENABLED" != "true" ]; then
        case "$role" in
          architect|tester) reason="rules disabled (PR_MERGED_FANOUT_RULES_ENABLED=false)" ;;
          *)                reason="not in default fanout" ;;
        esac
      else
        case "$role" in
          architect) reason="no needs-architect-review / agent:architect label" ;;
          tester)    reason="no needs-tester-signoff / agent:tester label" ;;
          *)         reason="not in default fanout" ;;
        esac
      fi
    fi
    local colour="$R"; [ "$wakes" = "yes" ] && colour="$G" && any_wakes=1
    printf "    %-16s ${colour}%-6s${D} %s\n" "$role" "$wakes" "$reason"
  done
  echo ""

  if [ "$any_wakes" -eq 0 ]; then
    printf "  ${Y}⚠ no role would wake for this PR${D} — pr_merged event will be skipped entirely.\n"
    printf "     (default-fanout is empty AND no label rules matched)\n\n"
  fi

  # --- ADR-0009 (D2.2): pr_labeled fanout (waking NOW on current label set) ---
  # Per ADR-0009 § 2.5, this section shows the wake decision against the PR's
  # CURRENT open-state labels. After merge + ADR-0007 cleanup, labels are
  # stripped and the wake column collapses to (none) for human-decision roles
  # — that's exactly the race ADR-0009 closes by firing at label-add time.
  # ADR-0009 § 6: empty string must disable the path (kill switch). Using
  # `${VAR-default}` (not `${VAR:-default}`) so empty string is honored and
  # only the unset case falls back to the default. Fixes BUG-1 (kill switch
  # was silently re-defaulted by `:-` on empty).
  PR_LABELED_FANOUT="${PR_LABELED_FANOUT-architect tester}"

  role_receives_pr_labeled() {
    local r="$1"
    case " $PR_LABELED_FANOUT " in
      *" $r "*) return 0 ;;
      *) return 1 ;;
    esac
  }
  role_wakes_for_pr_labeled() {
    local r="$1" labels_json="$2"
    case "$r" in
      architect)
        echo "$labels_json" | jq -e 'any(.[]?; . == "needs-architect-review" or . == "cc:architect" or . == "agent:architect")' >/dev/null 2>&1 && return 0
        ;;
      tester)
        echo "$labels_json" | jq -e 'any(.[]?; . == "needs-tester-signoff" or . == "cc:tester" or . == "agent:tester")' >/dev/null 2>&1 && return 0
        ;;
    esac
    return 1
  }

  printf "  ${B}pr_labeled fanout (ADR-0009 — waking NOW on current label set)${D}\n"
  printf "    PR_LABELED_FANOUT                = %s\n" "$(echo -n "$PR_LABELED_FANOUT" | sed 's/^$/(empty — pr_labeled disabled)/')"
  printf "    PR state                         = %s\n\n" "$state"

  # ADR-0009 § 2.5.1: --check-env parity with PR_MERGED_FANOUT_DEFAULT.
  # An empty PR_LABELED_FANOUT is a silent no-op landmine: PR-open routing
  # is disabled entirely and architect/tester will never wake on label-add.
  # Warn loudly — parallel to D-2.1.1's architect-skipped-on-merge fix.
  if [ -z "$PR_LABELED_FANOUT" ]; then
    printf "  ${Y}⚠ PR_LABELED_FANOUT is empty${D} — pr_labeled event disabled entirely.\n"
    printf "     architect/tester will NOT wake on PR label-add (ADR-0009 § 2.1 routing\n"
    printf "     skipped). If this is intentional, ignore. Otherwise:\n"
    printf "       export PR_LABELED_FANOUT=\"architect tester\"  # restore default\n\n"
  fi

  printf "    %-16s %-6s %s\n" "ROLE" "WAKES" "REASON"
  local any_lab_wakes=0
  for role in "${ROLES[@]}"; do
    local lwakes lreason
    if ! role_receives_pr_labeled "$role"; then
      lwakes="no"; lreason="not in PR_LABELED_FANOUT"
    elif [ "$state" != "OPEN" ]; then
      lwakes="no"; lreason="PR not open (state=$state) — pr_labeled only fires on open PRs"
    elif role_wakes_for_pr_labeled "$role" "$labels_json"; then
      lwakes="yes"
      any_lab_wakes=1
      case "$role" in
        architect) lreason="label match: needs-architect-review / cc:architect / agent:architect" ;;
        tester)    lreason="label match: needs-tester-signoff / cc:tester / agent:tester" ;;
        *)         lreason="label match" ;;
      esac
    else
      lwakes="no"
      case "$role" in
        architect) lreason="no needs-architect-review / cc:architect / agent:architect" ;;
        tester)    lreason="no needs-tester-signoff / cc:tester / agent:tester" ;;
        *)         lreason="not enrolled" ;;
      esac
    fi
    local lcolour="$R"; [ "$lwakes" = "yes" ] && lcolour="$G"
    printf "    %-16s ${lcolour}%-6s${D} %s\n" "$role" "$lwakes" "$lreason"
  done
  echo ""

  if [ "$state" != "OPEN" ] && [ "$any_lab_wakes" -eq 0 ]; then
    printf "  ${Y}ℹ Note:${D} this PR is %s. pr_labeled only fires while OPEN. If architect/tester were\n" "$state"
    printf "     supposed to wake for this PR, check that they did so before merge —\n"
    printf "     ADR-0007 cleanup strips needs-* labels post-merge by design (ADR-0009 § 4.1).\n\n"
  fi

  printf "  ${B}Override examples${D}\n"
  printf "    PR_MERGED_FANOUT_DEFAULT=\"\" %s --fanout %s            # rules-only mode\n" "$0" "$pr_num"
  printf "    PR_MERGED_FANOUT_RULES_ENABLED=false %s --fanout %s    # D2 behaviour (no labels)\n" "$0" "$pr_num"
  printf "    PR_LABELED_FANOUT=\"\" %s --fanout %s                   # disable D2.2 PR-open routing\n" "$0" "$pr_num"
  echo ""
}

# --- main dispatch ---
if [ "${1:-}" = "--alert" ]; then
  alert_mode
fi

if [ "${1:-}" = "--units" ]; then
  units_mode
  exit 0
fi

if [ "${1:-}" = "--fanout" ]; then
  fanout_mode "${2:-}"
  exit 0
fi

if [ $# -eq 0 ]; then
  printf "${B}agent-doctor — health check (stale threshold: ${STALE_SEC}s)${D}\n\n"
  any_stale=0
  for role in "${ROLES[@]}"; do
    role_health_line "$role" || any_stale=1
  done
  echo ""
  echo "  Tip: ./agent-doctor.sh <role>             — deep dive"
  echo "       ./agent-doctor.sh <role> --kick PAT  — surgical unblock"
  echo "       ./agent-doctor.sh --fanout <PR_NUM>  — ADR-0008 fanout simulator"
  exit $any_stale
fi

ROLE="$1"
shift || true

# Validate role
case "$ROLE" in
  orchestrator|product-manager|architect|developer|tester) ;;
  *) echo "ERROR: unknown role '$ROLE'. Valid: ${ROLES[*]}" >&2; exit 2 ;;
esac

if [ "${1:-}" = "--kick" ]; then
  PATTERN="${2:-}"
  if [ -z "$PATTERN" ]; then
    echo "ERROR: --kick requires a pattern (e.g. --kick pr-review-26)" >&2
    exit 2
  fi
  "$STATE_HELPER" kick "$ROLE" "$PATTERN"
  echo ""
  echo "Next poll (~60s) should re-emit events for matching PRs."
  echo "Watch:  tail -f ${LOG_DIR}/${ROLE}.watch.log"
  exit 0
fi

# --- restart subcommand (ADR-0006) ---
if [ "${1:-}" = "--restart" ]; then
  if unit_enabled "$ROLE"; then
    echo "Restarting $(unit_for "$ROLE") via systemd…"
    unit_restart "$ROLE"
    sleep 2
    if unit_active "$ROLE"; then
      printf "  status: ${G}active${D}, MainPID=%s\n" "$(unit_pid "$ROLE")"
      exit 0
    else
      printf "  status: ${R}failed${D} (check: journalctl --user -u $(unit_for "$ROLE") | tail -20)\n"
      exit 1
    fi
  else
    echo "systemd unit not enabled for $ROLE; falling back to nohup restart."
    echo "Consider running:  bash ${SCRIPT_DIR}/install/dev-studio-install-systemd.sh"
    pkill -f "agent-watch.sh ${ROLE}" || true
    sleep 1
    nohup bash "${SCRIPT_DIR}/agent-watch.sh" "${ROLE}" --loop \
      >> "${LOG_DIR}/${ROLE}.watch.log" 2>&1 &
    NEW_PID=$!
    echo "  nohup restart: PID=${NEW_PID}"
    exit 0
  fi
fi

role_deep_dive "$ROLE"
