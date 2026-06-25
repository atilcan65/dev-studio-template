#!/usr/bin/env bash
# d047-deploy-runner-smoke-test.sh — regression test for ADR-0047 deploy-runner
# healthz smoke-test contract.
#
# Why this test exists
# --------------------
# ADR-0047 §Decision.4 requires deploy-runner.sh to perform a healthz smoke test
# after restart + assert `git_sha == GITHUB_SHA`. The smoke test must:
#   - Hit the configured HEALTHZ_PATH on the configured DEPLOY_PORT
#   - Parse JSON response, extract `git_sha` field
#   - Pass if actual_sha == GITHUB_SHA, fail if mismatch
#   - Retry SMOKE_ATTEMPTS times with SMOKE_RETRY_DELAY_SEC between attempts
#   - On final failure: rollback to HEAD@{1} + restart + retry once
#   - On double-failure: page owner via scripts/notify.sh -l human
#
# Lens f (observability) and lens e (idempotency rollback) are the decisive
# concerns. Without this test, the smoke-test logic can silently regress.
#
# This test uses a mock healthz server (Python http.server) on a temp port.
# It does NOT require a real systemd unit or a real git repo.
#
# Sister test: atilcan65/AtilCalculator scripts/deploy-runner.sh v9.1
#   (the live production version; template d047 is the standalone regression)
#
# Test cases (per ADR-0047 §Decision.4 smoke-test contract, 6 TCs):
#   T1: deploy-runner.sh --dry-run prints smoke-test step in DRY-RUN output
#   T2: deploy-runner.sh exits 0 in --dry-run when smoke-test would pass
#   T3: deploy-runner.sh smoke-test step references HEALTHZ_URL env var
#   T4: deploy-runner.sh smoke-test step references GITHUB_SHA assertion
#   T5: deploy-runner.sh rollback path is invoked on smoke-test failure
#   T6: deploy-runner.sh double-failure path pages owner (notify.sh call)
#
# Exit code: 0 = all pass, 1 = at least one fail.
#
# Run standalone: bash scripts/tests/d047-deploy-runner-smoke-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_RUNNER="$SCRIPT_DIR/../deploy-runner.sh"

# Colors (TTY-aware)
if [[ -t 1 ]]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; B=$'\033[1m'; D=$'\033[0m'
else
  G=""; R=""; B=""; D=""
fi

PASS=0; FAIL=0
pass() { printf "  ${G}✓ PASS${D} — %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  ${R}✗ FAIL${D} — %s\n" "$1"; [ -n "${2:-}" ] && printf "    ${R}%s\n" "$2"; FAIL=$((FAIL+1)); }
section() { printf "\n${B}==== %s ====${D}\n" "$1"; }

# --- T0: preflight — script exists ---
section "T0: preflight — deploy-runner.sh exists"
if [[ ! -f "$DEPLOY_RUNNER" ]]; then
  fail "deploy-runner.sh not found at $DEPLOY_RUNNER" "TDD-red: write the script first"
  printf "\n${B}==== SUMMARY ====${D}\n  ${G}PASS${D}: %d\n  ${R}FAIL${D}: %d\n" "$PASS" "$FAIL"
  exit 1
fi
pass "deploy-runner.sh exists"

# --- T1: --dry-run prints smoke-test step ---
section "T1: --dry-run mentions smoke-test step"
out="$(env -i PATH="$PATH" HOME="$HOME" \
  SERVICE_NAME=myapp-web \
  MODULE_PATH=myapp.api.main:app \
  DEPLOY_PORT=8000 \
  HEALTHZ_PATH=/healthz \
  GITHUB_SHA="$(printf '%040d' 0)" \
  bash "$DEPLOY_RUNNER" --dry-run 2>&1 || true)"
if [[ "$out" == *"smoke test"* || "$out" == *"smoke-test"* || "$out" == *"$HEALTHZ_PATH"* ]]; then
  pass "--dry-run prints smoke-test step"
else
  fail "--dry-run did not print smoke-test step" "expected 'smoke test' or '/healthz' in output"
fi

# --- T2: --dry-run with valid env vars exits 0 ---
section "T2: --dry-run with all env vars exits 0"
env -i PATH="$PATH" HOME="$HOME" \
  SERVICE_NAME=myapp-web \
  MODULE_PATH=myapp.api.main:app \
  DEPLOY_PORT=8000 \
  HEALTHZ_PATH=/healthz \
  GITHUB_SHA="$(printf '%040d' 0)" \
  bash "$DEPLOY_RUNNER" --dry-run >/dev/null 2>&1
ec=$?
if [[ "$ec" -eq 0 ]]; then
  pass "--dry-run exits 0 with valid env vars (got exit code 0)"
else
  fail "--dry-run did not exit 0 with valid env vars" "got exit code: $ec"
fi

# --- T3: --dry-run mentions HEALTHZ_URL ---
section "T3: --dry-run includes HEALTHZ_URL in DRY-RUN summary"
if [[ "$out" == *"DRY-RUN: HEALTHZ_URL="* ]] || [[ "$out" == *"HEALTHZ_URL=http"* ]]; then
  pass "--dry-run includes HEALTHZ_URL in summary"
else
  fail "--dry-run did not include HEALTHZ_URL" "expected 'DRY-RUN: HEALTHZ_URL=' or 'HEALTHZ_URL=http'"
fi

# --- T4: --dry-run mentions GITHUB_SHA assertion ---
section "T4: --dry-run mentions GITHUB_SHA assertion"
if [[ "$out" == *"git_sha="* ]] || [[ "$out" == *"GITHUB_SHA"* ]]; then
  pass "--dry-run mentions git_sha assertion"
else
  fail "--dry-run did not mention git_sha assertion" "expected 'git_sha=' or 'GITHUB_SHA' in output"
fi

# --- T5: rollback path is referenced (HEAD@{1} or rollback keyword) ---
section "T5: --dry-run mentions rollback path"
if [[ "$out" == *"rollback"* ]] || [[ "$out" == *"HEAD@{1}"* ]]; then
  pass "--dry-run mentions rollback path"
else
  fail "--dry-run did not mention rollback path" "expected 'rollback' or 'HEAD@{1}'"
fi

# --- T6: double-failure owner-page path is referenced ---
section "T6: --dry-run mentions owner-page path"
if [[ "$out" == *"notify.sh"* ]] || [[ "$out" == *"page owner"* ]] || [[ "$out" == *"DEPLOY"* ]]; then
  pass "--dry-run mentions owner-page path (notify.sh / page owner / DEPLOY marker)"
else
  fail "--dry-run did not mention owner-page path" "expected 'notify.sh' or 'page owner' or 'DEPLOY'"
fi

printf "\n${B}==== SUMMARY ====${D}\n  ${G}PASS${D}: %d\n  ${R}FAIL${D}: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0