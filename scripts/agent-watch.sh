#!/usr/bin/env bash
# agent-watch.sh — GitHub-native autonomy: poll for new wake-up events for a role.
#
# Per ADR-0002 + ADR-0003 + ADR-0005 (Event Model v3): each agent's work queue
# lives on GitHub. This script queries the queue, diffs against the agent's
# state file, and emits new events as JSON.
#
# Event Model v3 (ADR-0005) adds `pr_merged` to the v2 taxonomy:
#   When a PR is merged, the watcher fans out a `pr-merged-<n>-<sha7>` event to
#   orchestrator + product-manager + developer (the post-merge lifecycle MVP).
#   Architect/tester get label-conditional fanout in a later iteration.
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
#         "kind": "issue_assigned|pr_review_requested|pr_new_commit|pr_comment_mention|stale_cc|label_change|pr_merged",
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

POLL_INTERVAL="$("$STATE_HELPER" get "$ROLE" poll_interval_sec)"
POLL_INTERVAL="${POLL_INTERVAL:-60}"

# v3.4 (issue #61 fix): HWM refresh on every poll.
#
# Bug (issue #61): `LAST_SEEN` / `PR_MERGED_LAST_SEEN` / `PR_LABELED_LAST_SEEN`
# were previously read ONCE at script start (this file, pre-fix) and never
# refreshed inside `poll_once`. In a long-running --loop watcher, the local
# HWM vars drifted behind the state file's HWM (which advances on every
# poll's tail), so the gh query kept returning historical events with old
# `updatedAt`. Combined with the FIFO trim on `processed_event_ids`, the
# dedup chain failed and events re-emitted indefinitely (board-50/52
# phantoms in the orchestrator's INBOX — 17+/8+ re-emissions per session).
#
# Fix: read all 3 HWMs from state at the start of every poll_once call (see
# `poll_once` below). The backfill logic stays — it runs on first call
# (state empty) and is a no-op thereafter. The two `init_*_hwm` functions
# are called from poll_once, NOT script-top, so the local vars are always
# fresh relative to the state file.
#
# Backfill window defaults are unchanged from v3/v3.2:
#   PR_MERGED_BACKFILL = '1 hour ago'   — long enough to span a brief
#                                         watcher restart, short enough
#                                         to not replay multi-day history.
#   PR_LABELED_BACKFILL = '60 seconds ago' — D2.2 § 2.3 / § 6: matches
#                                            default poll interval so we
#                                            don't miss a wake during a
#                                            brief restart.
PR_MERGED_BACKFILL="${PR_MERGED_BACKFILL:-1 hour ago}"
PR_LABELED_BACKFILL="${PR_LABELED_BACKFILL:-60 seconds ago}"

# init_pr_merged_hwm — read PR_MERGED_LAST_SEEN with first-run backfill.
# Idempotent. Sets the global var; called from poll_once.
init_pr_merged_hwm() {
  PR_MERGED_LAST_SEEN="$("$STATE_HELPER" get "$ROLE" pr_merged_last_seen_utc)"
  if [ -z "$PR_MERGED_LAST_SEEN" ] || [ "$PR_MERGED_LAST_SEEN" = "null" ]; then
    # GNU date (Linux) understands "-d '1 hour ago'"; BSD date (macOS) needs -v.
    PR_MERGED_LAST_SEEN="$(date -u -d "$PR_MERGED_BACKFILL" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
    if [ -z "$PR_MERGED_LAST_SEEN" ]; then
      # BSD fallback: extract "<N> <unit>" → -v-<N><U>; default to -1H if unparsable.
      bsd_num="$(printf '%s' "$PR_MERGED_BACKFILL" | awk '{print $1}')"
      bsd_unit="$(printf '%s' "$PR_MERGED_BACKFILL" | awk '{print $2}' | cut -c1 | tr '[:lower:]' '[:upper:]')"
      case "$bsd_unit" in M|H|D|W) : ;; *) bsd_num=1; bsd_unit=H ;; esac
      PR_MERGED_LAST_SEEN="$(date -u -v-"${bsd_num}${bsd_unit}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u '+%Y-%m-%dT%H:%M:%SZ')"
    fi
    "$STATE_HELPER" set "$ROLE" pr_merged_last_seen_utc "$PR_MERGED_LAST_SEEN"
  fi
}

# init_pr_labeled_hwm — read PR_LABELED_LAST_SEEN with first-run backfill.
# Idempotent. Sets the global var; called from poll_once.
init_pr_labeled_hwm() {
  PR_LABELED_LAST_SEEN="$("$STATE_HELPER" get "$ROLE" pr_labeled_last_seen_utc)"
  if [ -z "$PR_LABELED_LAST_SEEN" ] || [ "$PR_LABELED_LAST_SEEN" = "null" ]; then
    PR_LABELED_LAST_SEEN="$(date -u -d "$PR_LABELED_BACKFILL" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
    if [ -z "$PR_LABELED_LAST_SEEN" ]; then
      PR_LABELED_LAST_SEEN="$(date -u -v-60S '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u '+%Y-%m-%dT%H:%M:%SZ')"
    fi
    "$STATE_HELPER" set "$ROLE" pr_labeled_last_seen_utc "$PR_LABELED_LAST_SEEN"
  fi
}

# v3.1 (ADR-0008): label-conditional pr_merged fanout.
#
# Two layers:
#   1. PR_MERGED_FANOUT_DEFAULT — roles always woken on every merge (lifecycle).
#      D2 MVP value: "orchestrator product-manager developer".
#      Empty string = no default fanout (kill switch / debugging).
#   2. PR_MERGED_FANOUT_RULES_ENABLED=true|false — when true (default), the
#      following label patterns add extra roles per-PR:
#        - needs-architect-review or agent:architect → +architect
#        - needs-tester-signoff   or agent:tester    → +tester
#      When false, only the default set is used (D2 behaviour, full rollback).
#
# Per-role gating (`role_receives_pr_merged`) decides at poll time whether THIS
# watcher should run the pr_merged query at all. Without labels available it
# returns true for any role in DEFAULT (so we run the query and pick up labels);
# for architect/tester it also returns true when rules are enabled so they at
# least query merged PRs and let the per-PR filter decide later.
# Issue #52 (BUG-1 sibling): empty string must disable the default fanout
# (kill switch per ADR-0008 § 6). Using `${VAR-default}` (not `${VAR:-default}`)
# so empty string is honored and only the unset case falls back to default.
# Same fix as BUG-1 for PR_LABELED_FANOUT in PR #49 (commit 6823193).
PR_MERGED_FANOUT_DEFAULT="${PR_MERGED_FANOUT_DEFAULT-orchestrator product-manager developer}"
PR_MERGED_FANOUT_RULES_ENABLED="${PR_MERGED_FANOUT_RULES_ENABLED:-true}"

# v3.2 (ADR-0009): pr_labeled fanout — PR-open architect/tester routing.
# Closes ADR-0008 § 8.2 loop: architect/tester wake on label-add at PR-open
# time, BEFORE label-cleanup.yml (ADR-0007) can strip the wake-trigger label.
#
# Roles in PR_LABELED_FANOUT wake when an OPEN PR carries any wake-trigger
# label for their role (see role_wakes_for_pr_labeled). Empty string disables
# the entire path — kill switch matches ADR-0009 § 6 Reversal.
# ADR-0009 § 6: empty string must disable the path (kill switch). Using
# `${VAR-default}` (not `${VAR:-default}`) so empty string is honored and
# only the unset case falls back to the default. Fixes BUG-1 (kill switch
# was silently re-defaulted by `:-` on empty).
PR_LABELED_FANOUT="${PR_LABELED_FANOUT-architect tester}"

# True if $role is in the always-woken default set.
role_in_default_fanout() {
  local r="$1"
  case " $PR_MERGED_FANOUT_DEFAULT " in
    *" $r "*) return 0 ;;
    *) return 1 ;;
  esac
}

# True if $role can ever be woken by label rules (i.e. architect / tester when
# rules are enabled). Used as a query-gate so architect/tester actually run the
# gh query and we get to look at the labels.
role_eligible_via_label_rules() {
  [ "$PR_MERGED_FANOUT_RULES_ENABLED" = "true" ] || return 1
  case "$1" in
    architect|tester) return 0 ;;
    *) return 1 ;;
  esac
}

# Query-level gate: should this watcher even run query_pr_merged?
# Yes if role is in default OR rules might wake it via labels.
role_receives_pr_merged() {
  local r="$1"
  role_in_default_fanout "$r" && return 0
  role_eligible_via_label_rules "$r" && return 0
  return 1
}

# v3.2 (ADR-0009): pr_labeled gating + matching.
#
# role_receives_pr_labeled — query-level gate: is this role enrolled in
# PR_LABELED_FANOUT? If not, skip the gh pr list call entirely.
role_receives_pr_labeled() {
  local r="$1"
  case " $PR_LABELED_FANOUT " in
    *" $r "*) return 0 ;;
    *) return 1 ;;
  esac
}

# role_wakes_for_pr_labeled — per-PR filter: does the OPEN PR carry any of
# this role's wake-trigger labels? Per ADR-0009 § 2.1:
#   architect: needs-architect-review, cc:architect, agent:architect
#   tester:    needs-tester-signoff,   cc:tester,    agent:tester
# Exact-name match (NOT regex) per ADR-0009 § 2.1 "Correction to issue #47 AC".
#   $1 = role
#   $2 = JSON array of label name strings (from PR's labels field)
# Returns 0 (wake) / 1 (skip).
role_wakes_for_pr_labeled() {
  local r="$1" labels_json="$2"
  case "$r" in
    architect)
      echo "$labels_json" | jq -e '
        any(.[]?; . == "needs-architect-review" or . == "cc:architect" or . == "agent:architect")
      ' >/dev/null 2>&1 && return 0
      ;;
    tester)
      echo "$labels_json" | jq -e '
        any(.[]?; . == "needs-tester-signoff" or . == "cc:tester" or . == "agent:tester")
      ' >/dev/null 2>&1 && return 0
      ;;
  esac
  return 1
}

# pr_labeled_wake_reason — returns the first matching wake-trigger label name,
# for event observability (context.wake_reason per ADR-0009 § 2.2 / § 4.3).
pr_labeled_wake_reason() {
  local r="$1" labels_json="$2"
  case "$r" in
    architect)
      echo "$labels_json" | jq -r '
        (map(select(. == "needs-architect-review" or . == "cc:architect" or . == "agent:architect")) | .[0]) // ""
      '
      ;;
    tester)
      echo "$labels_json" | jq -r '
        (map(select(. == "needs-tester-signoff" or . == "cc:tester" or . == "agent:tester")) | .[0]) // ""
      '
      ;;
    *) echo "" ;;
  esac
}

# Per-PR fanout decision: given a role and a JSON labels array, should this PR
# wake the role? Inputs:
#   $1 = role
#   $2 = JSON array of label name strings (from pr_merged event context.labels)
# Returns 0 (wake) / 1 (skip). Used to filter pr_merged events role-by-role.
role_wakes_for_pr() {
  local r="$1" labels_json="$2"

  # Default-fanout roles always wake on merge (D2 behaviour preserved).
  if role_in_default_fanout "$r"; then
    return 0
  fi

  # Rules disabled → no extra fanout, default-only.
  [ "$PR_MERGED_FANOUT_RULES_ENABLED" = "true" ] || return 1

  # architect: needs-architect-review or agent:architect.
  # tester:   needs-tester-signoff   or agent:tester.
  case "$r" in
    architect)
      echo "$labels_json" | jq -e '
        any(.[]?; . == "needs-architect-review" or . == "agent:architect")
      ' >/dev/null 2>&1 && return 0
      ;;
    tester)
      echo "$labels_json" | jq -e '
        any(.[]?; . == "needs-tester-signoff" or . == "agent:tester")
      ' >/dev/null 2>&1 && return 0
      ;;
  esac
  return 1
}

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

# v3 (ADR-0005): post-merge lifecycle. Fan out pr-merged events to the roles
# listed in PR_MERGED_FANOUT_ROLES so developer/PM/orchestrator can run their
# cleanup workflows (branch prune, board update, sprint refresh) without manual
# pokes. Event ID = `pr-merged-<n>-<sha7>` where sha7 is the merge commit short
# SHA — unique per merge so re-merges (force-push to main, rare) re-fire cleanly.
#
# Dedup defense:
#   1. `pr_merged_last_seen_utc` high-water mark filters the gh query.
#   2. `processed_event_ids` ring buffer (poll_once) drops anything already seen.
#   3. Event ID embeds merge SHA — same PR re-merged with new SHA = new event.
# Side-channel: query_pr_merged exposes the newest merged_at it SAW (across all
# merged PRs in the window, regardless of label filter) via the global
# PR_MERGED_NEWEST_SEEN. This lets the HWM update advance even when label rules
# filter every PR out for this role — otherwise architect/tester would re-query
# the same backfill window forever and rely on dedup to suppress duplicates.
PR_MERGED_NEWEST_SEEN=""

query_pr_merged() {
  PR_MERGED_NEWEST_SEEN=""
  role_receives_pr_merged "$ROLE" || { echo '[]'; return; }

  # Fetch all merged PRs in the backfill window with their labels.
  local raw
  raw="$(gh pr list \
    --repo "$REPO" \
    --state merged \
    --search "merged:>${PR_MERGED_LAST_SEEN}" \
    --limit 50 \
    --json number,title,url,mergedAt,mergeCommit,author,labels \
    --jq "[ .[] |
           select(.mergeCommit != null and .mergeCommit.oid != null) |
           {
             id: (\"pr-merged-\" + (.number | tostring) + \"-\" + (.mergeCommit.oid[0:7])),
             kind: \"pr_merged\",
             number: .number,
             title: .title,
             url: .url,
             updated_at: .mergedAt,
             context: {
               merge_sha: .mergeCommit.oid[0:7],
               merged_at: .mergedAt,
               author: (.author.login // \"unknown\"),
               labels: [.labels[].name]
             }
           } ]")"

  # v3.1.1: bump HWM here (not in poll_once) so we don't depend on a global
  # surviving the $(query_pr_merged) subshell. Subshells lose parent vars.
  local newest
  newest="$(echo "$raw" | jq -r '[.[].context.merged_at] | max // empty')"
  PR_MERGED_NEWEST_SEEN="$newest"  # kept for backward compat / unit tests
  if [ -n "$newest" ] && [ "$newest" != "null" ]; then
    "$STATE_HELPER" set "$ROLE" pr_merged_last_seen_utc "$newest"
  fi

  # v3.1 (ADR-0008): per-PR label-conditional filter.
  # Default-fanout roles keep every PR (D2 behaviour, fast path).
  # Architect/tester only keep PRs whose labels match the configured rules.
  if role_in_default_fanout "$ROLE"; then
    echo "$raw"
    return
  fi

  # Walk the events one by one so each label set is checked by jq separately.
  local filtered='[]' n i evt labels
  n="$(echo "$raw" | jq 'length')"
  i=0
  while [ "$i" -lt "$n" ]; do
    evt="$(echo "$raw" | jq -c ".[$i]")"
    labels="$(echo "$evt" | jq -c '.context.labels')"
    if role_wakes_for_pr "$ROLE" "$labels"; then
      filtered="$(jq -c -n --argjson acc "$filtered" --argjson e "$evt" '$acc + [$e]')"
    fi
    i=$((i+1))
  done
  echo "$filtered"
}

# v3.2 (ADR-0009 D2.2): PR-open architect/tester routing via pr_labeled.
#
# Why not Events API? Per ADR-0009 § 3 "Alternatives", we use the cheaper
# `gh pr list --state open` query with PR.updatedAt as HWM proxy. Cost:
# 1 API call per role per poll (only architect/tester are enrolled by default,
# so 2 calls/min total). Trade-off vs label-event precision is logged as
# TD-002 (docs/tech-debt.md) with a 5%-suppression-rate payoff trigger.
#
# Event ID = `pr-labeled-<n>-<updatedAt>` — stable per (PR, wake-tick). Re-poll
# of the same PR within one updatedAt window produces the same ID, which the
# processed_event_ids ring suppresses. A force-push or comment bumps updatedAt
# → new ID → re-wake (acceptable; agent sees fresh signal).
#
# Suppression observability: when role_receives_pr_labeled is true but no PR
# matches role_wakes_for_pr_labeled, we still advance the HWM (D2.1.2 pattern).
# Future TD-002 instrumentation will log pr_labeled_suppressed_quick_removal
# when the dedup ring detects > 5% same-PR re-evaluation churn (deferred to D2.2.1).
PR_LABELED_NEWEST_SEEN=""

query_pr_labeled() {
  PR_LABELED_NEWEST_SEEN=""
  role_receives_pr_labeled "$ROLE" || { echo '[]'; return; }

  # Fetch all OPEN PRs with their labels + updatedAt.
  local raw
  raw="$(gh pr list \
    --repo "$REPO" \
    --state open \
    --limit 50 \
    --json number,title,url,updatedAt,labels,isDraft \
    --jq "[ .[] | select(.updatedAt > \"$PR_LABELED_LAST_SEEN\") |
           {
             number,
             title,
             url,
             updatedAt,
             isDraft,
             labels: [.labels[].name]
           } ]" 2>/dev/null || echo '[]')"

  # D2.1.2-style inline HWM bump: advance even when label filter drops all PRs.
  local newest
  newest="$(echo "$raw" | jq -r '[.[].updatedAt] | max // empty')"
  PR_LABELED_NEWEST_SEEN="$newest"
  if [ -n "$newest" ] && [ "$newest" != "null" ]; then
    "$STATE_HELPER" set "$ROLE" pr_labeled_last_seen_utc "$newest"
  fi

  # Per-PR filter: only keep PRs whose labels match this role's wake-trigger set.
  local filtered='[]' n i pr labels_json wake_reason
  n="$(echo "$raw" | jq 'length')"
  i=0
  while [ "$i" -lt "$n" ]; do
    pr="$(echo "$raw" | jq -c ".[$i]")"
    labels_json="$(echo "$pr" | jq -c '.labels')"
    if role_wakes_for_pr_labeled "$ROLE" "$labels_json"; then
      wake_reason="$(pr_labeled_wake_reason "$ROLE" "$labels_json")"
      filtered="$(jq -c -n \
        --argjson acc "$filtered" \
        --argjson p "$pr" \
        --arg reason "label:${wake_reason}" \
        '$acc + [{
          id: ("pr-labeled-" + ($p.number | tostring) + "-" + $p.updatedAt),
          kind: "pr_labeled",
          number: $p.number,
          title: $p.title,
          url: $p.url,
          updated_at: $p.updatedAt,
          context: {
            labels: $p.labels,
            wake_reason: $reason,
            pr_state: "open",
            isDraft: $p.isDraft
          }
        }]')"
    fi
    i=$((i+1))
  done
  echo "$filtered"
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

  # BUG-#61 fix: refresh HWMs from state at the start of every poll, so a
  # long-running --loop watcher's local HWM vars don't drift behind the state
  # file's HWM (which advances on every poll's tail below at `$STATE_HELPER set
  # ... last_seen_utc "$now"`). The 3 reads below were previously at script
  # start (pre-fix) and frozen there for the lifetime of the --loop process,
  # so the gh queries (query_assigned_issues, query_pr_mentions,
  # query_pr_merged, query_pr_labeled, query_board_changes) kept returning
  # historical events with old `updatedAt`.
  LAST_SEEN="$("$STATE_HELPER" get "$ROLE" last_seen_utc)"
  init_pr_merged_hwm
  init_pr_labeled_hwm

  local assigned reviews commits mentions stale board pr_merged pr_labeled
  assigned="$(query_assigned_issues || echo '[]')"
  reviews="$(query_review_requests || echo '[]')"
  commits="$(query_new_commits_on_assigned_prs || echo '[]')"
  mentions="$(query_pr_mentions 2>/dev/null || echo '[]')"
  stale="$(query_stale_cc 2>/dev/null || echo '[]')"
  board="$(query_board_changes || echo '[]')"
  pr_merged="$(query_pr_merged 2>/dev/null || echo '[]')"
  pr_labeled="$(query_pr_labeled 2>/dev/null || echo '[]')"

  # Merge and dedupe
  local merged
  merged="$(jq -s 'add | unique_by(.id)' \
    <(echo "$assigned") <(echo "$reviews") <(echo "$commits") \
    <(echo "$mentions") <(echo "$stale") <(echo "$board") \
    <(echo "$pr_merged") <(echo "$pr_labeled"))"

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

  # v3.1.1 (ADR-0008): HWM bump now lives inside query_pr_merged because the
  # subshell `$(query_pr_merged)` capture above drops any globals set by the
  # callee. The role still advances pr_merged_last_seen_utc on every poll even
  # when label rules filtered every PR out for this role.

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
