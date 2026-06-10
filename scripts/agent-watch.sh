#!/usr/bin/env bash
# agent-watch.sh — GitHub-native autonomy: poll for new wake-up events for a role.
#
# Per ADR-0002: each agent's work queue lives on GitHub. This script queries the
# queue, diffs against the agent's state file, and emits new events as JSON.
#
# Usage:
#   agent-watch.sh <role>           # one-shot: print new events JSON, exit
#   agent-watch.sh <role> --loop    # poll forever (sleeps poll_interval between checks)
#   agent-watch.sh <role> --once    # alias for one-shot (default)
#
# Output (JSON, to stdout):
#   {
#     "role": "<role>",
#     "polled_at_utc": "...",
#     "new_events": [
#       {
#         "id": "<unique event id>",
#         "kind": "issue_assigned|pr_review_requested|pr_comment_mention|label_change",
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
  # PRs with label cc:<role>, open, updated since last_seen.
  gh pr list \
    --repo "$REPO" \
    --label "cc:${ROLE}" \
    --state open \
    --limit 50 \
    --json number,title,url,updatedAt,isDraft,labels,headRefName \
    --jq "[ .[] | select(.updatedAt > \"$LAST_SEEN\") |
           {
             id: (\"pr-review-\" + (.number | tostring) + \"-\" + .updatedAt),
             kind: \"pr_review_requested\",
             number: .number,
             title: .title,
             url: .url,
             updated_at: .updatedAt,
             context: { isDraft: .isDraft, branch: .headRefName, labels: [.labels[].name] }
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
         map(select(.body != null and (.body | test(\"@${ROLE}\\\b\"; \"i\"))) |
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

# --- the actual poll ---
poll_once() {
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local assigned reviews mentions board
  assigned="$(query_assigned_issues || echo '[]')"
  reviews="$(query_review_requests || echo '[]')"
  mentions="$(query_pr_mentions 2>/dev/null || echo '[]')"
  board="$(query_board_changes || echo '[]')"

  # Merge and dedupe
  local merged
  merged="$(jq -s 'add | unique_by(.id)' \
    <(echo "$assigned") <(echo "$reviews") <(echo "$mentions") <(echo "$board"))"

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
