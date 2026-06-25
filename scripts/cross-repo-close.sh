# TEMPLATE PORT (Issue #372, RETRO-005 candidate): mirrors the AtilCalculator
# cross-repo-close.sh (MERGED with AtilCalc workflow). Future bootstrapped repos
# inherit this cross-repo close capability as part of the template bootstrap.
#
# Sister port to Issue #290 (wip-idle-detect, MERGED with PR #59 in template).
# Sister workflow: .github/workflows/cross-repo-close.yml (this PR).
#
#!/usr/bin/env bash
# cross-repo-close.sh — Bridge script for cross-repo PR auto-close.
#
# Implements Issue #293 + ADR-0040 (Option B). Reads "Closes/Fixes
# <org>/<repo>#N" patterns from a PR body and closes the referenced
# foreign-repo issues via the GitHub API. Used because GitHub's
# native "Closes #N" auto-close is single-repo only.
#
# Security caveats (ADR-0040 §5 caveats):
#   1. Dedicated PAT (CROSS_REPO_CLOSE_TOKEN) — set via CI env, NOT
#      the main PROJECT_TOKEN. Scope: contents:write + issues:write.
#   2. CI-only execution — invoked from .github/workflows/cross-repo-close.yml
#      on pull_request.closed events (NOT agent runtime; PAT must not leak).
#   3. Idempotent guard — pre-check issue state; skip if already CLOSED.
#   4. Graceful degradation — missing PAT or rate-limit → warn + PR comment
#      + exit 0 (NEVER exit 1, NEVER block PR merge).
#   5. Dry-run mode — `--dry-run` flag lists actions without executing.
#
# Invocation:
#   # Auto (CI workflow on PR merge):
#   CROSS_REPO_CLOSE_TOKEN=${{ secrets.CROSS_REPO_CLOSE_TOKEN }} \
#   PR_NUMBER=${{ github.event.pull_request.number }} \
#   REPO=${{ github.repository }} \
#     bash scripts/cross-repo-close.sh
#
#   # Manual review (dry-run):
#   PR_NUMBER=57 REPO=atilcan65/dev-studio-template \
#     bash scripts/cross-repo-close.sh --dry-run
#
# Exit codes:
#   0 — always (caveat 4: graceful degradation). Failures are logged
#       + PR-commented, never surfaced as exit 1.
#
# Audit log: ${AUDIT_LOG:-/var/log/dev-studio/cross-repo-close.log}
# Format: ISO-8601 UTC timestamp + LEVEL (OK/WARN/INFO/SKIP) + action

set -uo pipefail

# --- Configuration ---
AUDIT_LOG="${AUDIT_LOG:-/var/log/dev-studio/cross-repo-close.log}"
DRY_RUN=false

# --- Argument parsing (caveat 5) ---
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[$ts] $level $msg" >> "$AUDIT_LOG" 2>/dev/null || true
  echo "[$level] $msg"
}

# --- Caveat 4: Graceful degradation (missing PAT) ---
if [[ -z "${CROSS_REPO_CLOSE_TOKEN:-}" && "$DRY_RUN" == "false" ]]; then
  log "WARN" "CROSS_REPO_CLOSE_TOKEN missing — manual close needed"
  if [[ -n "${PR_NUMBER:-}" ]] && command -v gh >/dev/null 2>&1; then
    gh pr comment "$PR_NUMBER" --body "⚠️ cross-repo close deferred: CROSS_REPO_CLOSE_TOKEN missing. Manual close required." 2>/dev/null || true
  fi
  exit 0
fi

# --- Validate inputs (only when not dry-run) ---
if [[ "$DRY_RUN" == "false" ]]; then
  : "${PR_NUMBER:?PR_NUMBER env var required}"
  : "${REPO:?REPO env var required (e.g., atilcan65/AtilCalculator)}"
fi

# --- Caveat 5: Dry-run path ---
if [[ "$DRY_RUN" == "true" ]]; then
  log "INFO" "dry-run mode — would scan PR body for Closes/Fixes patterns"
  log "INFO" "PR_NUMBER=${PR_NUMBER:-<unset>} REPO=${REPO:-<unset>}"
  if [[ -n "${PR_NUMBER:-}" && -n "${REPO:-}" ]] && command -v gh >/dev/null 2>&1; then
    PR_BODY="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null || echo "")"
    CROSS_REFS="$(printf '%s\n' "$PR_BODY" | grep -oE '(Closes|Fixes) [a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+#[0-9]+' || true)"
    if [[ -z "$CROSS_REFS" ]]; then
      log "INFO" "dry-run: no cross-repo refs found"
    else
      log "INFO" "dry-run: would process the following refs:"
      while IFS= read -r ref; do
        echo "  [dry-run] $ref"
      done <<< "$CROSS_REFS"
    fi
  fi
  exit 0
fi

# --- Fetch PR body ---
PR_BODY="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null || echo "")"

# --- Extract cross-repo refs (Closes/Fixes <org>/<repo>#N) ---
CROSS_REFS="$(printf '%s\n' "$PR_BODY" | grep -oE '(Closes|Fixes) [a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+#[0-9]+' || true)"

if [[ -z "$CROSS_REFS" ]]; then
  log "INFO" "no-cross-refs PR=#${PR_NUMBER}"
  exit 0
fi

# --- Process each ref ---
PROCESSED=0
SKIPPED=0
FAILED=0

while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue

  KEYWORD="$(printf '%s' "$ref" | awk '{print $1}')"
  REPO_AND_NUM="$(printf '%s' "$ref" | awk '{print $2}')"
  FOREIGN_REPO="${REPO_AND_NUM%#*}"
  ISSUE_NUM="${REPO_AND_NUM#*#}"

  # Skip same-repo refs (handled by GitHub natively)
  if [[ "$FOREIGN_REPO" == "$REPO" ]]; then
    log "SKIP" "same-repo $FOREIGN_REPO#$ISSUE_NUM (handled natively)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # --- Caveat 3: Idempotent guard ---
  STATE="$(gh issue view "$ISSUE_NUM" --repo "$FOREIGN_REPO" --json state --jq '.state' 2>/dev/null || echo UNKNOWN)"
  if [[ "$STATE" == "CLOSED" ]]; then
    log "SKIP" "already-closed $FOREIGN_REPO#$ISSUE_NUM"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  log "INFO" "closing $FOREIGN_REPO#$ISSUE_NUM (referenced by $KEYWORD in PR #$PR_NUMBER)"

  # --- Close via gh api ---
  if gh api \
       -X PATCH "/repos/$FOREIGN_REPO/issues/$ISSUE_NUM" \
       -f state=closed \
       --header "Authorization: token $CROSS_REPO_CLOSE_TOKEN" \
       >/dev/null 2>&1; then
    log "OK" "closed $FOREIGN_REPO#$ISSUE_NUM via PR=#${PR_NUMBER}"
    PROCESSED=$((PROCESSED + 1))
  else
    # --- Caveat 4 (extended): API failure graceful ---
    log "WARN" "failed-close $FOREIGN_REPO#$ISSUE_NUM — manual close required"
    FAILED=$((FAILED + 1))
  fi
done <<< "$CROSS_REFS"

# --- Summary PR comment ---
SUMMARY="🤖 cross-repo-close: processed=$PROCESSED skipped=$SKIPPED failed=$FAILED"
if command -v gh >/dev/null 2>&1; then
  gh pr comment "$PR_NUMBER" --body "$SUMMARY" 2>/dev/null || true
fi
log "INFO" "summary PR=#${PR_NUMBER} processed=$PROCESSED skipped=$SKIPPED failed=$FAILED"

exit 0
