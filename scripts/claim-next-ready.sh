#!/usr/bin/env bash
# claim-next-ready.sh — ADR-0038 §Layer 2 atomic claim helper.
#
# Picks the highest-priority `agent:<role> AND status:ready` issue and
# atomically flips it to `status:in-progress`, then appends an audit log line.
# Sort key: priority (P0>P1>P2>P3>unknown) > age (oldest first). Skips items
# whose issue body references an open dependency (depends on #N / blocked by #N).
#
# Replaces the STUB introduced by Issue #276 (Sprint 4 closeout bridge, PR #277).
# STUB was a no-op (exit 0 + "deferred to Sprint 5"); this is the real Layer 2.
#
# Exit codes:
#   0  claimed (issue #N flipped, comment + audit log written)
#   1  nothing to claim (no status:ready items, or all blocked by open deps)
#   2  usage error (missing/invalid role argument)
#   3  WIP limit reached (>= WIP_LIMIT status:in-progress items already)
#   4  gh API error (network/auth/repo detection/jq failure)
#
# Env:
#   WIP_LIMIT              per-role WIP cap (default: 2, ADR-0002 §polling cadence)
#   GITHUB_REPO            override repo detection (default: gh repo view)
#   AUTO_CLAIM_LOG_DIR     override audit log dir (default: /var/log/dev-studio/<repo-name>)
#   CLAIM_NEXT_READY_ENABLED  kill switch (default: true; set false to disable)
#
# Reference: ADR-0038 §Layer 2, docs/designs/AUTO-CLAIM-PROTOCOL-design.md,
#            scripts/tests/d031-claim-next-ready.sh (5 TCs).

set -uo pipefail

ROLE="${1:-}"
WIP_LIMIT="${WIP_LIMIT:-2}"
ENABLED="${CLAIM_NEXT_READY_ENABLED:-true}"

# --- usage / role validation ---
if [ -z "$ROLE" ]; then
  echo "usage: claim-next-ready.sh <role>" >&2
  echo "  role: orchestrator|product-manager|architect|developer|tester" >&2
  exit 2
fi
case "$ROLE" in
  orchestrator|product-manager|architect|developer|tester) ;;
  *) echo "ERROR: invalid role: $ROLE" >&2; exit 2 ;;
esac

# --- kill switch ---
if [ "$ENABLED" != "true" ]; then
  echo "[claim-next-ready.sh] disabled (CLAIM_NEXT_READY_ENABLED=$ENABLED) — no claim"
  exit 1
fi

# --- repo detection ---
REPO="${GITHUB_REPO:-}"
if [ -z "$REPO" ]; then
  if command -v gh >/dev/null 2>&1; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
fi
if [ -z "$REPO" ]; then
  echo "ERROR: cannot detect repo. Set GITHUB_REPO=owner/name." >&2
  exit 4
fi

# --- preflight ---
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI required" >&2; exit 4; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 4; }

# --- WIP cap check (ADR-0002 §polling cadence, ADR-0038 risk #6) ---
wip_raw="$(gh issue list \
  --repo "$REPO" \
  --label "agent:${ROLE}" \
  --label "status:in-progress" \
  --state open \
  --json number \
  --jq 'length' 2>/dev/null)" || { echo "ERROR: gh API error (WIP query)" >&2; exit 4; }
wip_count="$(printf '%s' "$wip_raw" | tr -d '[:space:]')"
if ! [[ "$wip_count" =~ ^[0-9]+$ ]]; then
  echo "ERROR: unexpected WIP response: $wip_count" >&2
  exit 4
fi
if [ "$wip_count" -ge "$WIP_LIMIT" ]; then
  echo "[claim-next-ready.sh] WIP limit reached: $wip_count/$WIP_LIMIT — no claim" >&2
  exit 3
fi

# --- fetch ready items ---
ready_raw="$(gh issue list \
  --repo "$REPO" \
  --label "agent:${ROLE}" \
  --label "status:ready" \
  --state open \
  --limit 50 \
  --json number,title,createdAt,labels,body 2>/dev/null)" || { echo "ERROR: gh API error (ready query)" >&2; exit 4; }

ready_count="$(printf '%s' "$ready_raw" | jq 'length' 2>/dev/null || echo 0)"
if [ "$ready_count" = "0" ]; then
  echo "[claim-next-ready.sh] no ready items for role=$ROLE — no claim"
  exit 1
fi

# --- extract + sort: priority (P0>P1>P2>P3>unknown=9) > age (oldest first) ---
# age is createdAt (ISO 8601; lexicographic sort works for the same prefix).
sorted_json="$(printf '%s' "$ready_raw" | jq '
  [ .[] |
    . as $item |
    ([.labels[].name] | map(select(startswith("priority:"))) | first) as $plbl |
    (
      if   $plbl == "priority:P0" then 0
      elif $plbl == "priority:P1" then 1
      elif $plbl == "priority:P2" then 2
      elif $plbl == "priority:P3" then 3
      else 9
      end
    ) as $prio |
    {
      number: .number,
      title: .title,
      createdAt: .createdAt,
      body: (.body // ""),
      _priority: $prio,
      _priority_label: ($plbl // "priority:unknown"),
      _labels: ([.labels[].name])
    }
  ] | sort_by([._priority, .createdAt])
')" || { echo "ERROR: jq sort failed" >&2; exit 4; }

# --- iterate candidates, skip those with open deps (try-next per ADR-0038 risk #4) ---
# Conservative regex: (?i)(depends on|blocked by) #<digits>. "Refs #N" is
# informational only (does NOT trigger skip). The regex bounds captured groups
# to digits, so no shell eval of arbitrary text (T3 mitigation in design).
picked_number=""
picked_priority_label=""
skipped_dep_summary=""
total_candidates="$(printf '%s' "$sorted_json" | jq 'length')"
i=0
while [ "$i" -lt "$total_candidates" ]; do
  candidate="$(printf '%s' "$sorted_json" | jq -c ".[$i]")"
  cnum="$(printf '%s' "$candidate" | jq -r '.number')"
  cbody="$(printf '%s' "$candidate" | jq -r '.body // ""')"
  cprio="$(printf '%s' "$candidate" | jq -r '._priority_label')"

  open_dep=""
  dep_candidates="$(printf '%s' "$cbody" | grep -oiE '(depends on|blocked by) #[0-9]+' | grep -oE '[0-9]+' | sort -un || true)"
  for dep_n in $dep_candidates; do
    [ -z "$dep_n" ] && continue
    dep_state="$(gh issue view "$dep_n" --repo "$REPO" --json state -q .state 2>/dev/null || echo "unknown")"
    if [ "$dep_state" = "open" ]; then
      open_dep="$dep_n"
      break
    fi
  done

  if [ -z "$open_dep" ]; then
    picked_number="$cnum"
    picked_priority_label="$cprio"
    break
  fi
  skipped_dep_summary="${skipped_dep_summary}#$cnum(dep=#$open_dep) "
  i=$((i + 1))
done

if [ -z "$picked_number" ]; then
  echo "[claim-next-ready.sh] all $total_candidates candidate(s) blocked by open deps [$skipped_dep_summary]— no claim"
  exit 1
fi

# --- atomic claim: status:ready → status:in-progress + comment + audit log ---
now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
wip_after=$((wip_count + 1))

if ! gh issue edit "$picked_number" --repo "$REPO" \
    --remove-label "status:ready" \
    --add-label "status:in-progress" >/dev/null 2>&1; then
  echo "ERROR: gh issue edit failed for #$picked_number" >&2
  exit 4
fi

# Comment is best-effort (warn on failure but still exit 0 since the flip succeeded).
if ! gh issue comment "$picked_number" --repo "$REPO" --body "🤖 **auto-claimed by $ROLE at $now_iso (WIP=$wip_after/$WIP_LIMIT)**

Per ADR-0038 §Auto-Claim Protocol. Priority=$picked_priority_label." >/dev/null 2>&1; then
  echo "WARN: comment failed for #$picked_number (claim still recorded)" >&2
fi

# Audit log: append-only, ISO-8601 + role + issue + wip + priority (ADR-0036 pattern).
repo_name="${REPO##*/}"
log_dir="${AUTO_CLAIM_LOG_DIR:-/var/log/dev-studio/${repo_name}}"
mkdir -p "$log_dir" 2>/dev/null || true
audit_log="$log_dir/auto-claim.log"
echo "$now_iso $ROLE claimed #$picked_number (WIP=$wip_after/$WIP_LIMIT, $picked_priority_label)" \
  >> "$audit_log" 2>/dev/null || echo "WARN: audit log write failed at $audit_log" >&2

echo "claimed #$picked_number (WIP=$wip_after/$WIP_LIMIT, $picked_priority_label)"
exit 0
