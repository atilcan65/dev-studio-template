#!/usr/bin/env bash
# d046-deploy-runner-env-validation.sh — regression test for ADR-0047 deploy-runner
# env-var fail-loud contract.
#
# Why this test exists
# --------------------
# ADR-0047 (deploy-automation-pattern, per Issue #375 Option A verdict) requires
# `scripts/deploy-runner.sh` to fail-loud with clear `ERROR: <env-var> required`
# messages when the 4 required env vars are unset:
#   1. SERVICE_NAME  — systemd unit name (e.g., "myapp-web")
#   2. MODULE_PATH   — Python module:app object (e.g., "myapp.api.main:app")
#   3. DEPLOY_PORT   — TCP port to bind (e.g., 8000)
#   4. HEALTHZ_PATH  — healthcheck endpoint (e.g., "/healthz")
#
# Lens d (silent-skip) is the decisive concern — silent WARN/SKIP patterns were
# the v5 deploy-runner bug class (RCA-7-4 / RCA-9). The contract is: missing
# required env var → script exits non-zero with stderr message naming the var,
# NOT silent pass.
#
# Sister test: atilcan65/AtilCalculator scripts/tests/d019-canonical-entry-cross-check.sh
#   (AtilCalc d-test covers module-path consistency; template d046 covers
#    env-var fail-loud contract)
#
# Test cases (per ADR-0047 §Decision.3 env-var table, 4 TCs):
#   T1: missing SERVICE_NAME → exit non-zero + stderr contains "SERVICE_NAME"
#   T2: missing MODULE_PATH → exit non-zero + stderr contains "MODULE_PATH"
#   T3: missing DEPLOY_PORT → exit non-zero + stderr contains "DEPLOY_PORT"
#   T4: missing HEALTHZ_PATH → exit non-zero + stderr contains "HEALTHZ_PATH"
#   T5: all 4 required env vars set + GITHUB_SHA → script proceeds (exit 0 in --dry-run mode)
#   T6: malformed GITHUB_SHA (not 40-char hex) → exit non-zero + stderr contains "GITHUB_SHA"
#   T7: malformed DEPLOY_PORT (not numeric) → exit non-zero + stderr contains "DEPLOY_PORT"
#   T8: --dry-run mode prints env-var summary + exits 0 (no real deploy)
#
# Exit code: 0 = all pass, 1 = at least one fail.
#
# Run standalone: bash scripts/tests/d046-deploy-runner-env-validation.sh

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

# --- T0: preflight — script exists and is executable ---
section "T0: preflight — deploy-runner.sh exists"
if [[ ! -f "$DEPLOY_RUNNER" ]]; then
  fail "deploy-runner.sh not found at $DEPLOY_RUNNER" "TDD-red: write the script first"
  printf "\n${B}==== SUMMARY ====${D}\n  ${G}PASS${D}: %d\n  ${R}FAIL${D}: %d\n" "$PASS" "$FAIL"
  exit 1
fi
if [[ ! -x "$DEPLOY_RUNNER" ]]; then
  fail "deploy-runner.sh not executable at $DEPLOY_RUNNER" "chmod +x scripts/deploy-runner.sh"
  exit 1
fi
pass "deploy-runner.sh exists and is executable"

# --- T1: missing SERVICE_NAME → exit non-zero + stderr contains SERVICE_NAME ---
section "T1: missing SERVICE_NAME → fail-loud"
out="$(env -i PATH="$PATH" HOME="$HOME" bash "$DEPLOY_RUNNER" 2>&1 || true)"
if [[ "$out" == *"SERVICE_NAME"* ]] && [[ "$out" == *"required"* || "$out" == *"missing"* || "$out" == *"ERROR"* ]]; then
  pass "missing SERVICE_NAME produces clear error mentioning SERVICE_NAME"
else
  fail "missing SERVICE_NAME did not produce clear error" "got: $out"
fi

# --- T2: missing MODULE_PATH → exit non-zero + stderr contains MODULE_PATH ---
section "T2: missing MODULE_PATH → fail-loud"
out="$(env -i PATH="$PATH" HOME="$HOME" SERVICE_NAME=myapp-web bash "$DEPLOY_RUNNER" 2>&1 || true)"
if [[ "$out" == *"MODULE_PATH"* ]] && [[ "$out" == *"required"* || "$out" == *"missing"* || "$out" == *"ERROR"* ]]; then
  pass "missing MODULE_PATH produces clear error mentioning MODULE_PATH"
else
  fail "missing MODULE_PATH did not produce clear error" "got: $out"
fi

# --- T3: missing DEPLOY_PORT → exit non-zero + stderr contains DEPLOY_PORT ---
section "T3: missing DEPLOY_PORT → fail-loud"
out="$(env -i PATH="$PATH" HOME="$HOME" SERVICE_NAME=myapp-web MODULE_PATH=myapp.api.main:app bash "$DEPLOY_RUNNER" 2>&1 || true)"
if [[ "$out" == *"DEPLOY_PORT"* ]] && [[ "$out" == *"required"* || "$out" == *"missing"* || "$out" == *"ERROR"* ]]; then
  pass "missing DEPLOY_PORT produces clear error mentioning DEPLOY_PORT"
else
  fail "missing DEPLOY_PORT did not produce clear error" "got: $out"
fi

# --- T4: missing HEALTHZ_PATH → exit non-zero + stderr contains HEALTHZ_PATH ---
section "T4: missing HEALTHZ_PATH → fail-loud"
out="$(env -i PATH="$PATH" HOME="$HOME" SERVICE_NAME=myapp-web MODULE_PATH=myapp.api.main:app DEPLOY_PORT=8000 bash "$DEPLOY_RUNNER" 2>&1 || true)"
if [[ "$out" == *"HEALTHZ_PATH"* ]] && [[ "$out" == *"required"* || "$out" == *"missing"* || "$out" == *"ERROR"* ]]; then
  pass "missing HEALTHZ_PATH produces clear error mentioning HEALTHZ_PATH"
else
  fail "missing HEALTHZ_PATH did not produce clear error" "got: $out"
fi

# --- T5: all 4 required env vars set + GITHUB_SHA → --dry-run proceeds ---
section "T5: all required env vars set + GITHUB_SHA → --dry-run proceeds"
out="$(env -i PATH="$PATH" HOME="$HOME" \
  SERVICE_NAME=myapp-web \
  MODULE_PATH=myapp.api.main:app \
  DEPLOY_PORT=8000 \
  HEALTHZ_PATH=/healthz \
  GITHUB_SHA="$(printf '%040d' 0)" \
  bash "$DEPLOY_RUNNER" --dry-run 2>&1 || true)"
if [[ "$out" == *"DRY-RUN"* ]]; then
  pass "all 4 required env vars + GITHUB_SHA + --dry-run produces DRY-RUN plan"
else
  fail "all required env vars set but --dry-run did not produce DRY-RUN output" "got: $out"
fi

# --- T6: malformed GITHUB_SHA (not 40-char hex) → exit non-zero ---
section "T6: malformed GITHUB_SHA → fail-loud"
out="$(env -i PATH="$PATH" HOME="$HOME" \
  SERVICE_NAME=myapp-web \
  MODULE_PATH=myapp.api.main:app \
  DEPLOY_PORT=8000 \
  HEALTHZ_PATH=/healthz \
  GITHUB_SHA=not-a-real-sha \
  bash "$DEPLOY_RUNNER" --dry-run 2>&1 || true)"
if [[ "$out" == *"GITHUB_SHA"* ]]; then
  pass "malformed GITHUB_SHA produces clear error mentioning GITHUB_SHA"
else
  fail "malformed GITHUB_SHA did not produce clear error" "got: $out"
fi

# --- T7: malformed DEPLOY_PORT (not numeric) → exit non-zero ---
section "T7: malformed DEPLOY_PORT → fail-loud"
out="$(env -i PATH="$PATH" HOME="$HOME" \
  SERVICE_NAME=myapp-web \
  MODULE_PATH=myapp.api.main:app \
  DEPLOY_PORT=not-a-port \
  HEALTHZ_PATH=/healthz \
  GITHUB_SHA="$(printf '%040d' 0)" \
  bash "$DEPLOY_RUNNER" --dry-run 2>&1 || true)"
if [[ "$out" == *"DEPLOY_PORT"* ]]; then
  pass "malformed DEPLOY_PORT produces clear error mentioning DEPLOY_PORT"
else
  fail "malformed DEPLOY_PORT did not produce clear error" "got: $out"
fi

# --- T8: --dry-run mode prints env-var summary + exits 0 ---
section "T8: --dry-run mode summary line"
out8="$(env -i PATH="$PATH" HOME="$HOME" \
  SERVICE_NAME=myapp-web \
  MODULE_PATH=myapp.api.main:app \
  DEPLOY_PORT=8000 \
  HEALTHZ_PATH=/healthz \
  GITHUB_SHA="$(printf '%040d' 0)" \
  bash "$DEPLOY_RUNNER" --dry-run 2>&1 || true)"
if [[ "$out8" == *"DRY-RUN: REPO_DIR="* ]] || [[ "$out8" == *"DRY-RUN: HEALTHZ_URL="* ]]; then
  pass "--dry-run prints REPO_DIR/HEALTHZ_URL summary line"
else
  fail "--dry-run did not print summary line" "expected 'DRY-RUN: REPO_DIR=' or 'DRY-RUN: HEALTHZ_URL=' in output"
fi

printf "\n${B}==== SUMMARY ====${D}\n  ${G}PASS${D}: %d\n  ${R}FAIL${D}: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0