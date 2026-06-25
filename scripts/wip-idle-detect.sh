#!/usr/bin/env bash
# wip-idle-detect.sh — ADR-0039 WIP-idle watchdog helper.
#
# TEMPLATE PORT (Issue #290, Sprint 6 P1): mirrors the AtilCalculator
# implementation (scripts/wip-idle-detect.sh MERGED via Issue #291 dev impl).
# Future bootstrapped repos inherit the proactive WIP-idle doctrine from the
# template, so they don't repeat the WIP-full-but-idle pattern we fixed in
# AtilCalc. Owner doctrine (2026-06-23T10:08Z): "WIP dolu iken boş
# durmamaları gerek hiçbir agentın."
#
# Detects agents with `WIP > 0 + no activity 30m` per ADR-0039 §Decision.
# Emits a JSON array of idle roles for the orchestrator's wake loop to consume.
#
# Detection signals (per ADR-0039 §Decision, 3 in-scope for this impl):
#   1. PR draft updated in last 30m        (gh pr list --author <role-bot> --state draft --json updatedAt)
#   2. Issue comment posted in last 30m    (gh issue list --label agent:<role> --state open → comments updatedAt)
#   3. Branch commit pushed in last 30m    (gh api repos/.../commits?sha=<branch>&since=<30m ago>)
#
# State-machine edge case (signal 5):
#   - Agent with `status:in-review` PR → NOT idle (legitimate wait, not pause).
#   - Detected via: `gh pr list --label agent:<role> --state open --search "is:pr is:open"`
#     filtered by `status:in-review` label.
#
# Out of scope (this impl, deferred per ADR-0039 §Decision signal 4):
#   - Worktree file activity (local file edits invisible to GH API).
#     Mitigation: agents post a heartbeat comment ("drafting, ETA 45m") to signal activity.
#
# Usage:
#   bash scripts/wip-idle-detect.sh                    # scan all 5 roles
#   bash scripts/wip-idle-detect.sh --role developer   # single role
#   bash scripts/wip-idle-detect.sh --threshold 45     # override 30m threshold (debug)
#   bash scripts/wip-idle-detect.sh --dry-run          # print idle list without notify
#
# Output (stdout): JSON array
#   [ {"role":"developer", "wip_count":1, "issues":[291], "age_min":47}, ... ]
#
# Exit codes:
#   0  scan completed (regardless of idle count)
#   1  usage error (invalid role flag, missing --)
#   2  gh API error (network/auth/jq failure)
#   3  preflight fail (gh/jq not in PATH)
#
# Env:
#   WIP_IDLE_THRESHOLD_MIN   override threshold minutes (default: 30, ADR-0039 §Decision)
#   GITHUB_REPO              override repo (default: gh repo view)
#   DRY_RUN                  when set, skip notify.sh emission (default: unset)
#
# Reference: ADR-0039 §Decision + §Detection signals, scripts/claim-next-ready.sh (template),
#            scripts/tests/d034-proactive-wip-idle.sh (regression, 8 TUs).

set -uo pipefail

ROLE_FLAG=""
THRESHOLD_MIN="${WIP_IDLE_THRESHOLD_MIN:-30}"
DRY_RUN="${DRY_RUN:-}"

# --- arg parse ---
while [ $# -gt 0 ]; do
  case "$1" in
    --role)         ROLE_FLAG="$2"; shift 2 ;;
    --threshold)    THRESHOLD_MIN="$2"; shift 2 ;;
    --dry-run)      DRY_RUN="1"; shift ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *)
      echo "usage: wip-idle-detect.sh [--role <role>] [--threshold <min>] [--dry-run]" >&2
      echo "  role: orchestrator|product-manager|architect|developer|tester (default: all 5)" >&2
      exit 1
      ;;
  esac
done

# --- preflight ---
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI required" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 3; }

# --- repo detection ---
REPO="${GITHUB_REPO:-}"
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
if [ -z "$REPO" ]; then
  echo "ERROR: cannot detect repo. Set GITHUB_REPO=owner/name." >&2
  exit 2
fi

# --- role list (default: all 5) ---
ALL_ROLES="orchestrator product-manager architect developer tester"
if [ -n "$ROLE_FLAG" ]; then
  case "$ROLE_FLAG" in
    orchestrator|product-manager|architect|developer|tester) ROLES="$ROLE_FLAG" ;;
    *) echo "ERROR: invalid role: $ROLE_FLAG" >&2; exit 1 ;;
  esac
else
  ROLES="$ALL_ROLES"
fi

# --- helper: ISO timestamp → epoch minutes ---
iso_to_min() {
  # $1 = ISO 8601 string, $2 = now epoch (seconds). Echoes age in minutes (integer).
  local iso="$1"
  local now_epoch="$2"
  local iso_epoch
  iso_epoch="$(date -u -d "$iso" +%s 2>/dev/null || echo 0)"
  if [ "$iso_epoch" = "0" ]; then echo "-1"; return; fi
  echo $(( (now_epoch - iso_epoch) / 60 ))
}

now_epoch="$(date -u +%s)"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- main scan ---
idle_json="[]"
for role in $ROLES; do
  # Signal 5 edge case: PR-in-review for this role = NOT idle
  in_review_count="$(gh pr list \
    --repo "$REPO" \
    --label "agent:${role}" \
    --label "status:in-review" \
    --state open \
    --json number \
    --jq 'length' 2>/dev/null || echo "0")"

  if [ "${in_review_count:-0}" -gt 0 ]; then
    # Skip this role — signal 5: legitimate wait, not pause.
    continue
  fi

  # Fetch WIP items for this role
  wip_issues="$(gh issue list \
    --repo "$REPO" \
    --label "agent:${role}" \
    --label "status:in-progress" \
    --state open \
    --limit 50 \
    --json number,title,updatedAt 2>/dev/null)" || { echo "ERROR: gh API error (WIP query for $role)" >&2; exit 2; }

  wip_count="$(echo "$wip_issues" | jq 'length')"
  [ "$wip_count" -eq 0 ] && continue

  # For each WIP issue, check activity signals
  idle_issues_json="[]"
  for issue_n in $(echo "$wip_issues" | jq -r '.[].number'); do
    # Signal 2: issue comment in last 30m
    last_comment_iso="$(gh issue view "$issue_n" --repo "$REPO" \
      --json comments --jq '[.comments[].updatedAt] | max // empty' 2>/dev/null || echo "")"
    comment_age_min="-1"
    if [ -n "$last_comment_iso" ] && [ "$last_comment_iso" != "null" ]; then
      comment_age_min="$(iso_to_min "$last_comment_iso" "$now_epoch")"
    fi

    # Signal 1: PR draft updated in last 30m (issues with linked PRs)
    pr_draft_age_min="-1"
    pr_draft_json="$(gh pr list --repo "$REPO" --state open --search "linked:issue-$issue_n is:draft" \
      --json updatedAt --jq '.[0].updatedAt // empty' 2>/dev/null || echo "")"
    if [ -n "$pr_draft_json" ] && [ "$pr_draft_json" != "null" ]; then
      pr_draft_age_min="$(iso_to_min "$pr_draft_json" "$now_epoch")"
    fi

    # Signal 3: branch commit in last 30m on PRs linked to this issue
    commit_age_min="-1"
    pr_branch="$(gh pr list --repo "$REPO" --state open --search "linked:issue-$issue_n" \
      --json headRefName --jq '.[0].headRefName // empty' 2>/dev/null || echo "")"
    if [ -n "$pr_branch" ]; then
      last_commit_iso="$(gh api "repos/${REPO}/commits?sha=${pr_branch}&per_page=1" \
        --jq '.[0].commit.committer.date // empty' 2>/dev/null || echo "")"
      if [ -n "$last_commit_iso" ] && [ "$last_commit_iso" != "null" ]; then
        commit_age_min="$(iso_to_min "$last_commit_iso" "$now_epoch")"
      fi
    fi

    # Idle if ALL signals either missing (-1) or older than threshold
    is_idle="true"
    for age in "$comment_age_min" "$pr_draft_age_min" "$commit_age_min"; do
      if [ "$age" -ge 0 ] && [ "$age" -lt "$THRESHOLD_MIN" ]; then
        is_idle="false"
        break
      fi
    done

    if [ "$is_idle" = "true" ]; then
      # Compute max age for reporting
      max_age=0
      for age in "$comment_age_min" "$pr_draft_age_min" "$commit_age_min"; do
        if [ "$age" -gt "$max_age" ]; then max_age="$age"; fi
      done
      idle_issues_json="$(echo "$idle_issues_json" | jq --argjson n "$issue_n" --argjson age "$max_age" \
        '. + [{issue: $n, age_min: $age}]')"
    fi
  done

  issue_count="$(echo "$idle_issues_json" | jq 'length')"
  if [ "$issue_count" -gt 0 ]; then
    idle_json="$(echo "$idle_json" | jq --arg r "$role" --argjson n "$issue_count" --argjson iss "$idle_issues_json" \
      '. + [{role: $r, wip_count: $n, issues: $iss}]')"
  fi
done

# --- output ---
if [ -n "$DRY_RUN" ]; then
  echo "$idle_json" | jq .
  exit 0
fi

# Production: emit JSON for orchestrator's wake loop to consume
echo "$idle_json" | jq .

# Optional: trigger notify.sh if any idle detected (orchestrator integration)
# Wave coalesce: per ADR-0039 arch 🟡 #2 — ≥3 idle roles in 5-min window = single
# `[ORCH→ALL] idle wave: <roles>` instead of N individual pings. Wave logic lives
# in scripts/agent-watch.sh's `query_wip_idle` integration (the orchestrator's
# wake loop coalesces across agents before dispatching notify.sh). This helper
# emits per-role idle JSON; the watcher is responsible for the wave.
idle_total="$(echo "$idle_json" | jq 'length')"
if [ "$idle_total" -ge 1 ] && [ "${WIP_IDLE_AUTO_NOTIFY:-0}" = "1" ]; then
  for role in $(echo "$idle_json" | jq -r '.[].role'); do
    issues_str="$(echo "$idle_json" | jq -r --arg r "$role" '.[].issues[].issue | select(. != null)' | head -3 | tr '\n' ',')"
    notify_msg="[WIP-IDLE] $role: ${issues_str%,} idle ${THRESHOLD_MIN}m+ (WIP>0, no activity)"
    bash "$(dirname "$0")/notify.sh" -l "$role" "$notify_msg" >/dev/null 2>&1 || true
  done
fi

exit 0