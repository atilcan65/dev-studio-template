#!/usr/bin/env bash
# bootstrap-test-project.sh — S2 AC1 gate for PR-T4 / PR-T5 (ADR generalization)
#
# Refs:
#   - Issue #48 (AtilCalculator), PR-T1..PR-T7 plan
#   - Architect review on #48 (2026-06-21T06:48:40Z, 🟢 + 5🟡)
#   - S2 (Architect): "spawn 2nd project from template + grep for
#     AtilCalculator-specific strings → expect 0 matches"
#   - DEV response on #48 (2026-06-21T06:54:29Z) — proposed adding this
#     script as AC1 gate for PR-T4 (ADR-0020 generalize) and PR-T5
#     (ADR-0021 generalize)
#
# Purpose:
#   After PR-T1..PR-T7 ship to dev-studio-template, every new project
#   cloned from the template must be project-agnostic — no
#   AtilCalculator-specific strings leaking into ADRs / docs / soul files.
#   This script is the regression gate.
#
# Usage:
#   scripts/bootstrap-test-project.sh [TARGET_DIR]
#
# Defaults:
#   TARGET_DIR = /tmp/bootstrap-test-$(date +%s)
#   REPO       = origin (the template repo this script lives in)
#
# Exit codes:
#   0 = clean clone + 0 AtilCalculator-string matches (template is generic)
#   1 = clone or bootstrap failed
#   2 = AtilCalculator-string matches found (template leaked project refs)
#
# NOT YET FUNCTIONAL — scaffold only. Implementation lands in follow-up
# commit once architect's G1.c specs (atomic-label-edit.sh + label-tx.yml)
# and S2 AC1 test scaffolding are in place.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET_DIR="${1:-/tmp/bootstrap-test-$(date +%s)}"
TEMPLATE_REPO="${TEMPLATE_REPO:-$(git -C "$TEMPLATE_REPO_ROOT" remote get-url origin 2>/dev/null || echo "")}"

# AtilCalculator-specific strings that MUST NOT leak into a generic template.
# Update this list when a new project-specific reference is discovered.
readonly LEAK_PATTERNS=(
  "AtilCalculator"
  "atilcan65"
  "atilcan06"
  "#44\b" "#45\b" "#46\b" "#47\b"   # Sprint 1 issue numbers (Sprint-1-specific)
  "RCA-7\b" "RCA-8\b" "RCA-9\b"     # Sprint 3 incident references
)

echo "==> bootstrap-test-project.sh (scaffold)"
echo "    target   : $TARGET_DIR"
echo "    template : $TEMPLATE_REPO"
echo "    patterns : ${LEAK_PATTERNS[*]}"

if [[ -z "$TEMPLATE_REPO" ]]; then
  echo "ERROR: could not detect template repo origin. Run from a clone." >&2
  exit 1
fi

# TODO(pr-T-prep): implement clone + bootstrap + grep gate
#
# Pseudocode:
#   1. mkdir -p "$TARGET_DIR"
#   2. git clone --depth=1 "$TEMPLATE_REPO" "$TARGET_DIR/repo"
#   3. cd "$TARGET_DIR/repo" && bash scripts/dev-studio-init.sh \
#        --project-name "bootstrap-test" --dry-run
#   4. if grep -rEn "${LEAK_PATTERNS[*]}" docs/decisions/ .claude/ \
#         scripts/ 2>/dev/null; then
#        echo "FAIL: AtilCalculator-specific strings found in template"
#        exit 2
#      fi
#   5. echo "PASS: template is project-agnostic"
#   6. exit 0

echo "STUB: actual clone/bootstrap/grep logic lands in follow-up commit"
exit 0
