#!/usr/bin/env bash
# bootstrap-labels.sh — idempotent label seeding for a project that uses this template.
#
# Per ADR-0002: the autonomy loop needs a standard label set. This script ensures
# all required labels exist on the target repo. Safe to re-run.
#
# Usage:
#   bootstrap-labels.sh                       # uses current repo
#   bootstrap-labels.sh owner/name            # explicit repo

set -euo pipefail

REPO="${1:-}"
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" || {
    echo "ERROR: cannot determine repo. Pass owner/name or run inside the repo." >&2
    exit 2
  }
fi

echo "Seeding labels on $REPO ..."

# Format: name|color|description
LABELS=(
  # Priority
  "priority:P0|d73a4a|Critical — blocks all work, fix immediately"
  "priority:P1|fbca04|High — fix this sprint"
  "priority:P2|0e8a16|Medium — fix next sprint"
  "priority:P3|c5def5|Low — nice to have"
  # Type
  "type:feature|a2eeef|New feature or capability"
  "type:bug|d73a4a|Bug or defect"
  "type:chore|cccccc|Maintenance, refactor, deps"
  "type:docs|0075ca|Documentation"
  "type:refactor|c2e0c6|Code restructuring without behaviour change"
  "type:incident|b60205|Production incident or outage"
  # Status
  "status:backlog|ededed|Not yet started, in backlog"
  "status:ready|0e8a16|Ready to be picked up"
  "status:in-progress|fbca04|Currently being worked on"
  "status:in-review|0052cc|PR open, under review"
  "status:blocked|d73a4a|Blocked by external dependency"
  "status:done|0e8a16|Completed"
  # Agent (assignment)
  "agent:orchestrator|5319e7|Assigned to Orchestrator agent"
  "agent:pm|5319e7|Assigned to Product Manager agent"
  "agent:architect|5319e7|Assigned to Architect agent"
  "agent:developer|5319e7|Assigned to Developer agent"
  "agent:tester|5319e7|Assigned to Tester agent"
  # CC (review fanout) — per ADR-0002
  "cc:orchestrator|bfdadc|Review/awareness from Orchestrator"
  "cc:pm|bfdadc|Review/awareness from Product Manager"
  "cc:architect|bfdadc|Review/awareness from Architect"
  "cc:developer|bfdadc|Review/awareness from Developer"
  "cc:tester|bfdadc|Review/awareness from Tester"
  # Meta
  "good-first-issue|7057ff|Good for newcomers"
  "agent-stall|d93f0b|Agent stuck — needs intervention"
  "needs-human|d93f0b|Requires human decision"
  "security|ee0701|Security-sensitive — handle with care"
  "needs-architect-review|c2e0c6|Awaiting architect alignment review"
  "needs-tester-signoff|c2e0c6|Awaiting tester sign-off"
)

CREATED=0
UPDATED=0
SKIPPED=0
for entry in "${LABELS[@]}"; do
  IFS='|' read -r name color desc <<< "$entry"
  # Check existence
  if gh label list --repo "$REPO" --search "$name" --json name --jq ".[] | select(.name == \"$name\") | .name" 2>/dev/null | grep -qx "$name"; then
    # Update color + desc to keep template fresh (idempotent)
    gh label edit "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null 2>&1 && {
      UPDATED=$((UPDATED + 1))
      echo "  ~ $name (updated)"
    } || {
      SKIPPED=$((SKIPPED + 1))
      echo "  · $name (unchanged)"
    }
  else
    if gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null 2>&1; then
      CREATED=$((CREATED + 1))
      echo "  + $name (created)"
    else
      echo "  ! $name (failed)" >&2
    fi
  fi
done

echo ""
echo "Done. Created: $CREATED  Updated: $UPDATED  Skipped: $SKIPPED"
