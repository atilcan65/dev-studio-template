#!/usr/bin/env bash
# agent-watch.sh — GitHub-native autonomy: poll for new wake-up events for a role.
#
# Per ADR-0002 + ADR-0003 (Event Model v2): each agent's work queue lives on
# GitHub. This script queries the queue, diffs against the agent's state file,
# and emits new events as JSON.
#
# Event Model v2 (ADR-0003):
#   Event IDs include `headRefOid` (commit SHA) for PR events, so a new push
#   to a PR where cc:<role> is active = new event = re-wake (fixes the
#   "developer pushed fix but tester didn't re-verify" silent-failure class).
#
#   Stale-cc detector: if cc:<role> has been on a PR for > stale_threshold_sec
#   without any state change, emit a `stale_cc` event so deadlocks self-heal.
#
#   Heartbeat: after each poll the watcher bumps `last_heartbeat_utc`. A side
#   alarm (agent-doctor.sh / cron) raises a Telegram warn if a role's
#   heartbeat is stale, so silent watcher death is impossible to miss.
#
# Usage:
#   agent-watch.sh <role>           # one-shot: print new events JSON, exit
#   agent-watch.sh <role> --loop    # poll forever (sleeps poll_interval between checks)
#   agent-watch.sh <role> --once    # alias for one-shot (default)
#
# Env:
#   WAKE_PANE=1   — when new_events > 0, send a wake-up prompt to the role's
#                   tmux pane via `tmux send-keys`. Auto-enabled in --loop mode.
#                   Override with WAKE_PANE=0 to disable.
#   TMUX_SESSION  — session name to address (default: dev-studio)
#   STALE_CC_SEC  — seconds before cc:<role> on an unchanged PR is "stale"
#                   (default: 900 = 15 min)
#
# Output (JSON, to stdout):
#   {
#     "role": "<role>",
#     "polled_at_utc": "...",
#     "new_events": [
#       {
#         "id": "<unique event id>",
#         "kind": "issue_assigned|pr_review_requested|pr_new_commit|pr_comment_mention|stale_cc|label_change",
#         "number": <int>,
#         "title": "<str>",
#         "url": "<str>",
#         "updated_at": "<utc>",
#         "context": { ...kind-specific... }
#       }
#     ],
#     "next_poll_sec": 60
#   }
#
# Exit codes:
#   0  — success (may have 0 new events)
#   2  — usage error
#   3  — gh CLI not authenticated
#   4  — repo not detected (not inside a git repo or no GITHUB_REPO env)
#   5  — state helper missing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_HELPER="$SCRIPT_DIR/agent-state.sh"
ROLE="${1:-}"
MODE="${2:---once}"
TMUX_SESSION="${TMUX_SESSION:-dev-studio}"
STALE_CC_SEC="${STALE_CC_SEC:-900}"
# WAKE_PANE: 0/1. Auto-enabled in --loop mode unless explicitly set to 0.
WAKE_PANE_DEFAULT=0
[ "$MODE" = "--loop" ] && WAKE_PANE_DEFAULT=1
WAKE_PANE="${WAKE_PANE:-$WAKE_PANE_DEFAULT}"

if [ -z "$ROLE" ]; then
  echo "Usage: $0 <role> [--once|--loop]" >&2
  exit 2
fi

if [ ! -x "$STATE_HELPER" ]; then
  echo "ERROR: agent-state.sh missing or not executable at $STATE_HELPER" >&2
  exit 5
fi

# --- repo detection ---
REPO="${GITHUB_REPO:-}"
if [ -z "$REPO" ]; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
  fi
fi

if [ -z "$REPO" ]; then
  echo "ERROR: cannot determine repo. Set GITHUB_REPO=owner/name or run inside repo." >&2
  exit 4
fi

# --- preflight ---
require_jq() {
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 127; }
}
require_gh() {
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI required" >&2; exit 127; }
}
require_jq
require_gh

# Ensure state file exists
"$STATE_HELPER" init "$ROLE" >/dev/null

LAST_SEEN="$("$STATE_HELPER" get "$ROLE" last_seen_utc)"
POLL_INTERVAL="$("$STATE_HELPER" get "$ROLE" poll_interval_sec)"
POLL_INTERVAL="${POLL_INTERVAL:-60}"

# --- query builders (role-specific filters) ---
# Returns a JSON array of event objects (may be empty).
query_assigned_issues() {
  # Issues with label agent:<role> AND status:ready, updated after last_seen.
  gh issue list \
    --repo "$REPO" \
    --label "agent:${ROLE}" \
    --state open \
    --limit 50 \
    --json number,title,url,updatedAt,labels \
    --jq "[ .[] | select(.updatedAt > \"$LAST_SEEN\") |
           {
             id: (\"issue-assigned-\" + (.number | tostring) + \"-\" + .updatedAt),
             kind: \"issue_assigned\",
             number: .number,
             title: .title,
             url: .url,
             updated_at: .updatedAt,
             context: { labels: [.labels[].name] }
           } ]"
}

query_review_requests() {
  # PRs with label cc:<role>, open.
  # Event ID includes headRefOid (commit SHA) — a new push on an assigned PR
  # therefore yields a new event ID, breaking the dedup tie and waking the agent.
  # This is the v2 fix for the "developer pushed fix but tester didn't re-verify"
  # silent-failure bug.
  gh pr list \
    --repo "$REPO" \
    --label "cc:${ROLE}" \
    --state open \
    --limit 50 \
    --json number,title,url,updatedAt,isDraft,labels,headRefName,headRefOid \
    --jq "[ .[] |
           {
             id: (\"pr-review-\" + (.number | tostring) + \"-\" + (.headRefOid[0:7]) + \"-\" + .updatedAt),
             kind: \"pr_review_requested\",
             number: .number,
             title: .title,
             url: .url,
             updated_at: .updatedAt,
             context: {
               isDraft: .isDraft,
               branch: .headRefName,
               head_sha: .headRefOid[0:7],
               labels: [.labels[].name]
             }
           } ]"
}

query_new_commits_on_assigned_prs() {
  # Explicit "new commit on cc:<role> PR" event — covers the case where
  # updatedAt didn't change enough to clear last_seen but the commit SHA did.
  # Belt-and-suspenders with query_review_requests; either firing wakes the agent.
  gh pr list \
    --repo "$REPO" \
    --label "cc:${ROLE}" \
    --state open \
    --limit 50 \
    --json number,title,url,updatedAt,headRefOid,headRefName \
    --jq "[ .[] |
           {
             id: (\"pr-commit-\" + (.number | tostring) + \"-\" + (.headRefOid[0:7])),
             kind: \"pr_new_commit\",
             number: .number,
             title: .title,
             url: .url,
             updated_at: .updatedAt,
             context: { head_sha: .headRefOid[0:7], branch: .headRefName }
           } ]"
}

query_pr_mentions() {
  # PRs where a comment mentions @<role> since last_seen.
  # We list open PRs touched after last_seen, then inspect their comments.
  local prs
  prs="$(gh pr list \
    --repo "$REPO" \
    --state open \
    --limit 30 \
    --json number,title,url,updatedAt \
    --jq "[ .[] | select(.updatedAt > \"$LAST_SEEN\") ]")"

  echo "$prs" | jq -r '.[].number' | while read -r num; do
    [ -z "$num" ] && continue
    gh pr view "$num" --repo "$REPO" --json number,title,url,comments,reviews \
      --jq "
        ([.comments[], .reviews[]] |
         map(select(.body != null and (.body | test(\"@${ROLE}\\\\b\"; \"i\"))) |
             select(.createdAt > \"$LAST_SEEN\" or .submittedAt > \"$LAST_SEEN\")) |
         map({
           id: (\"pr-mention-\" + (\$num | tostring) + \"-\" + (.id // (.createdAt // .submittedAt))),
           kind: \"pr_comment_mention\",
           number: \$num,
           title: \"\",
           url: \"https://github.com/${REPO}/pull/\(\$num)\",
           updated_at: (.createdAt // .submittedAt),
           context: {
             author: (.author.login // \"unknown\"),
             body_preview: (.body[:300])
           }
         }))" \
      --jq-arg num "$num" 2>/dev/null || true
  done | jq -s 'add // []'
}

query_stale_cc() {
  # Deadlock breaker: if cc:<role> has sat on a PR for > STALE_CC_SEC without
  # any state change (no new commit, no new review, no label flip), emit a
  # stale_cc event. The agent picks it up and either acts or explicitly punts
  # the label back. Prevents permanent stall when an event was lost (watcher
  # restart, tmux send-keys race, processed_event_ids corruption).
  #
  # The event ID is bucketed by 5-minute windows so the same stall doesn't
  # spam wake-ups every poll — it re-fires at most every ~5 min until cleared.
  local now_epoch bucket
  now_epoch="$(date -u +%s)"
  bucket=$(( now_epoch / 300 ))

  gh pr list \
    --repo "$REPO" \
    --label "cc:${ROLE}" \
    --state open \
    --limit 50 \
    --json number,title,url,updatedAt,headRefOid \
    --jq "[ .[] |
           ((now - (.updatedAt | fromdateiso8601)) | floor) as \$age |
           select(\$age > ${STALE_CC_SEC}) |
           {
             id: (\"stale-cc-\" + (.number | tostring) + \"-\" + (.headRefOid[0:7]) + \"-b${bucket}\"),
             kind: \"stale_cc\",
             number: .number,
             title: .title,
             url: .url,
             updated_at: .updatedAt,
             context: {
               age_sec: \$age,
               head_sha: .headRefOid[0:7],
               note: \"cc:${ROLE} unchanged for >${STALE_CC_SEC}s; deadlock-breaker wake.\"
             }
           } ]"
}

# Orchestrator has a wider lens: all label changes on any issue/PR.
query_board_changes() {
  if [ "$ROLE" != "orchestrator" ]; then
    echo "[]"
    return
  fi
  # Recent issue events for label/assignee changes since last_seen.
  gh issue list \
    --repo "$REPO" \
    --state all \
    --limit 50 \
    --json number,title,url,updatedAt,labels,state \
    --jq "[ .[] | select(.updatedAt > \"$LAST_SEEN\") |
           {
             id: (\"board-\" + (.number | tostring) + \"-\" + .updatedAt),
             kind: \"label_change\",
             number: .number,
             title: .title,
             url: .url,
             updated_at: .updatedAt,
             context: { state: .state, labels: [.labels[].name] }
           } ]"
}

# --- tmux pane wake-up (title-based) ---
# Find pane by title (role uppercase) and inject a wake-up prompt via send-keys.
# Safe to call when not inside tmux — silently no-ops.
wake_pane_for_role() {
  local role="$1"
  local events_json="$2"
  local count
  count="$(echo "$events_json" | jq 'length')"
  [ "$count" -gt 0 ] || return 0

  # tmux available?
  command -v tmux >/dev/null 2>&1 || return 0
  tmux has-session -t "$TMUX_SESSION" 2>/dev/null || return 0

  # Find pane id by title (uppercase role). Fallback: deterministic index map.
  local role_upper
  role_upper="$(echo "$role" | tr '[:lower:]' '[:upper:]')"

  local pane_id
  pane_id="$(tmux list-panes -t "$TMUX_SESSION" -F '#{pane_id} #{pane_title}' 2>/dev/null \
    | awk -v t="$role_upper" '$2 == t { print $1; exit }')"

  # Fallback index map (matches dev-studio-start.sh layout)
  if [ -z "$pane_id" ]; then
    case "$role" in
      orchestrator)    pane_id="${TMUX_SESSION}:main.0" ;;
      product-manager) pane_id="${TMUX_SESSION}:main.1" ;;
      architect)       pane_id="${TMUX_SESSION}:main.2" ;;
      developer)       pane_id="${TMUX_SESSION}:main.3" ;;
      tester)          pane_id="${TMUX_SESSION}:main.4" ;;
      *) return 0 ;;
    esac
  fi

  # Compose pretty-printed wake-up prompt (heredoc-safe).
  local pretty
  pretty="$(echo "$events_json" | jq '.')"

  local prompt
  prompt="🔔 INBOX (auto-wake from agent-watch loop):
${pretty}

Lütfen pickup et: review yap, label flip et, peer'i bilgilendir, sonra standby."

  # Send prompt then Enter. Use literal mode (-l) so backticks/quotes survive.
  tmux send-keys -t "$pane_id" -l "$prompt" 2>/dev/null || return 0
  tmux send-keys -t "$pane_id" Enter 2>/dev/null || true
}

# --- the actual poll ---
poll_once() {
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Heartbeat FIRST — even if the rest fails, doctor can see we're alive.
  "$STATE_HELPER" heartbeat "$ROLE" >/dev/null 2>&1 || true

  local assigned reviews commits mentions stale board
  assigned="$(query_assigned_issues || echo '[]')"
  reviews="$(query_review_requests || echo '[]')"
  commits="$(query_new_commits_on_assigned_prs || echo '[]')"
  mentions="$(query_pr_mentions 2>/dev/null || echo '[]')"
  stale="$(query_stale_cc 2>/dev/null || echo '[]')"
  board="$(query_board_changes || echo '[]')"

  # Merge and dedupe
  local merged
  merged="$(jq -s 'add | unique_by(.id)' \
    <(echo "$assigned") <(echo "$reviews") <(echo "$commits") \
    <(echo "$mentions") <(echo "$stale") <(echo "$board"))"

  # Filter out events already in processed_event_ids
  local state_file new_events
  state_file="$("$STATE_HELPER" path "$ROLE")"
  new_events="$(jq -n \
    --slurpfile state "$state_file" \
    --argjson events "$merged" '
    [ $events[] | select((.id as $id | $state[0].processed_event_ids | index($id)) == null) ]
  ')"

  # Emit
  jq -n \
    --arg role "$ROLE" \
    --arg now "$now" \
    --argjson events "$new_events" \
    --argjson next "$POLL_INTERVAL" \
    '{
       role: $role,
       polled_at_utc: $now,
       new_events: $events,
       next_poll_sec: $next
     }'

  # Bump last_seen
  "$STATE_HELPER" set "$ROLE" last_seen_utc "$now"

  # Auto-mark events as processed (the agent can also call mark explicitly)
  echo "$new_events" | jq -r '.[].id' | while read -r eid; do
    [ -n "$eid" ] && "$STATE_HELPER" mark "$ROLE" "$eid"
  done

  # Trim processed_event_ids to keep state file bounded (default: keep last 50).
  "$STATE_HELPER" trim "$ROLE" >/dev/null 2>&1 || true

  # Wake the tmux pane if events arrived and wake mode is on.
  if [ "$WAKE_PANE" = "1" ]; then
    wake_pane_for_role "$ROLE" "$new_events" || true
  fi
}

case "$MODE" in
  --once)
    poll_once
    ;;
  --loop)
    while true; do
      poll_once
      sleep "$POLL_INTERVAL"
    done
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    exit 2
    ;;
esac
