#!/usr/bin/env bash
# scripts/deploy-runner.sh — generic deploy-runner for dev-studio-template (ADR-0047)
#
# Why this script exists
# ----------------------
# Codifies the deploy-automation pattern as an env-driven, project-agnostic
# script. Sister to AtilCalculator scripts/deploy-runner.sh (v9.1) but generalized:
#   - No hardcoded service name, module path, port, or healthz path
#   - 4 required env vars (SERVICE_NAME, MODULE_PATH, DEPLOY_PORT, HEALTHZ_PATH)
#   - 1 optional env var (PROD_HOSTNAME — warn-only validation, lens g)
#   - nohup+setsid restart pattern (NOT systemctl --user) — per ADR-0047 §Decision.2
#
# Sister script: atilcan65/AtilCalculator scripts/deploy-runner.sh (v9.1, RCA-7/9/11/12/14
#                hardening preserved; the AtilCalc-specific service name + module path
#                + port + healthz path are now env vars in this template version).
#
# Pattern sources:
#   - AtilCalculator ADR-0027 (auto-deploy on main merge → SSH pull + restart)
#   - AtilCalculator ADR-0030 (self-hosted runner for LAN deploy)
#   - AtilCalculator RCA-7/9/11/12/14/16 hardening (FAIL-or-CREATE preflight,
#     cross-user port check, post-restart etimes check, idempotent converge)
#
# Test cases (per ADR-0047 §Decision.3 + §Decision.4):
#   d046-deploy-runner-env-validation.sh: 8 TCs (env-var fail-loud contract)
#   d047-deploy-runner-smoke-test.sh:      6 TCs (smoke-test + rollback contract)
#
# Exit codes (per ADR-0047 §Decision.5):
#   0  — smoke test passed, prod running the expected SHA
#   1  — smoke test failed but rollback succeeded; deploy should be retried
#   2  — smoke test failed AND rollback failed; owner paged, manual fix needed
#   3  — usage / configuration error (missing or malformed env vars)
#   4  — preflight failure (REPO_DIR missing, uv pip install failed, etc.)
#
# Usage on prod host:
#   SERVICE_NAME=myapp-web \
#   MODULE_PATH=myapp.api.main:app \
#   DEPLOY_PORT=8000 \
#   HEALTHZ_PATH=/healthz \
#   GITHUB_SHA=<40-char-hex> \
#   bash scripts/deploy-runner.sh
#
#   ...same env vars + --dry-run to print the plan without executing.

set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
fail() { log "ERROR: $*"; exit "${2:-1}"; }

# --- 1. Required env-var validation (lens d fail-loud contract, d046 T1-T4) ---
: "${SERVICE_NAME:?SERVICE_NAME required (e.g., myapp-web)}"
: "${MODULE_PATH:?MODULE_PATH required (e.g., myapp.api.main:app)}"
: "${DEPLOY_PORT:?DEPLOY_PORT required (numeric, e.g., 8000)}"
: "${HEALTHZ_PATH:?HEALTHZ_PATH required (e.g., /healthz)}"

# --- 2. Env-var shape validation (d046 T6 + T7) ---
if ! [[ "$DEPLOY_PORT" =~ ^[0-9]+$ ]]; then
  fail "DEPLOY_PORT must be numeric, got: $DEPLOY_PORT" 3
fi
if [[ -z "${GITHUB_SHA:-}" ]]; then
  fail "GITHUB_SHA env var is required (caller must pass it; the GH Action does this automatically)" 3
fi
if ! [[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  fail "GITHUB_SHA must be a 40-char hex SHA, got: $GITHUB_SHA" 3
fi

# --- 3. Hostname validation (lens g, arch refinement #1 — parameterize, don't drop) ---
ACTUAL_HOSTNAME="$(hostname 2>/dev/null || echo 'unknown')"
if [[ -n "${PROD_HOSTNAME:-}" ]]; then
  log "Deploy target hostname: $ACTUAL_HOSTNAME (expected prod: $PROD_HOSTNAME)"
  if [[ "$ACTUAL_HOSTNAME" != "$PROD_HOSTNAME" ]]; then
    log "WARN: hostname '$ACTUAL_HOSTNAME' is not the documented prod host '$PROD_HOSTNAME'"
    log "WARN: continuing — operator must confirm this is intentional"
  fi
else
  log "PROD_HOSTNAME not set — skipping hostname validation (lens g safety net is opt-in)"
  log "Recommended: set PROD_HOSTNAME in deploy.yml to catch accidental deploys to wrong hosts"
fi

# --- 4. Config (env-driven so the same script works in --dry-run and prod) ---
REPO_DIR="${REPO_DIR:-${GITHUB_WORKSPACE:-$(pwd)}}"
DEPLOY_HOST="${DEPLOY_HOST:-127.0.0.1}"
DEPLOY_BIND_HOST="${DEPLOY_BIND_HOST:-0.0.0.0}"
HEALTHZ_URL="http://${DEPLOY_HOST}:${DEPLOY_PORT}${HEALTHZ_PATH}"
HEALTHZ_TIMEOUT_SEC="${HEALTHZ_TIMEOUT_SEC:-5}"
SMOKE_ATTEMPTS="${SMOKE_ATTEMPTS:-5}"
SMOKE_RETRY_DELAY_SEC="${SMOKE_RETRY_DELAY_SEC:-2}"

# --- 5. Parse flags ---
DRY_RUN="false"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="true"
fi

# --- 6. --dry-run: print the plan, then exit 0 ---
if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY-RUN: no changes will be made"
  log "DRY-RUN: SERVICE_NAME=$SERVICE_NAME"
  log "DRY-RUN: MODULE_PATH=$MODULE_PATH"
  log "DRY-RUN: REPO_DIR=$REPO_DIR"
  log "DRY-RUN: GITHUB_SHA=$GITHUB_SHA"
  log "DRY-RUN: HEALTHZ_URL=$HEALTHZ_URL"
  log "DRY-RUN: DEPLOY_HOST=$DEPLOY_HOST DEPLOY_BIND_HOST=$DEPLOY_BIND_HOST DEPLOY_PORT=$DEPLOY_PORT"
  log "DRY-RUN: step 1: cd $REPO_DIR && git fetch origin && git reset --hard origin/main"
  log "DRY-RUN: step 2: preflight — ensure .venv exists (FAIL-or-CREATE pattern, ADR-0027 RCA-9)"
  log "DRY-RUN: step 3: preflight — uv pip install -p .venv -e . (RCA-7-4 stale deps)"
  log "DRY-RUN: step 4: restart — pkill uvicorn + nohup setsid .venv/bin/uvicorn $MODULE_PATH --host \$DEPLOY_BIND_HOST --port \$DEPLOY_PORT (nohup+setsid per ADR-0047 §Decision.2)"
  log "DRY-RUN: step 5: smoke test GET $HEALTHZ_URL (expecting git_sha=$GITHUB_SHA)"
  log "DRY-RUN: step 6 (on smoke-test failure): git reset --hard HEAD@{1} + restart + retry"
  log "DRY-RUN: step 7 (on double failure): page owner via scripts/notify.sh -l human"
  exit 0
fi

# --- 7. Preflight — REPO_DIR + curl ---
if [[ ! -d "$REPO_DIR" ]]; then
  fail "REPO_DIR does not exist: $REPO_DIR" 3
fi
if ! command -v curl >/dev/null 2>&1; then
  fail "curl not found on PATH (smoke test requires it)" 3
fi

cd "$REPO_DIR"

# --- 8. Step 1: idempotent converge to origin/main (ADR-0027 §Decision.5) ---
log "Fetching origin (REPO_DIR=$REPO_DIR)"
git fetch origin
log "Resetting to origin/main (target SHA=$GITHUB_SHA)"
git reset --hard origin/main

# Sanity: confirm we landed on the SHA the workflow requested.
actual_sha="$(git rev-parse HEAD)"
if [[ "$actual_sha" != "$GITHUB_SHA" ]]; then
  fail "post-reset HEAD ($actual_sha) != GITHUB_SHA ($GITHUB_SHA); something is very wrong" 1
fi
log "HEAD is at $actual_sha — matches GITHUB_SHA"

# --- 9. Step 2: preflight dep install (RCA-7-4 + RCA-9 + RCA-11) ---
# Optional — only if .venv directory exists. Templates may use a different
# runtime (e.g., system Python). This step is FAIL-or-CREATE.
if [[ -d "$REPO_DIR/.venv" ]] || grep -q '\[project\.optional-dependencies\]' "$REPO_DIR/pyproject.toml" 2>/dev/null; then
  if ! command -v uv >/dev/null 2>&1; then
    fail "uv not found on PATH (RCA-9 — preflight dep install requires uv). Install uv or pre-create $REPO_DIR/.venv manually." 4
  fi
  if [[ ! -d "$REPO_DIR/.venv" ]]; then
    log "Preflight: .venv missing at $REPO_DIR/.venv — creating via uv venv (RCA-9 fix)"
    if ! uv venv "$REPO_DIR/.venv" 2>&1 | tee /tmp/deploy-uv-venv.log; then
      fail "uv venv creation failed (RCA-9). See /tmp/deploy-uv-venv.log." 4
    fi
  fi
  log "Preflight: installing prod runtime surface via uv pip install -p .venv -e . (RCA-7-4 + RCA-9)"
  if ! uv pip install -p "$REPO_DIR/.venv" -e . 2>&1 | tee /tmp/deploy-uv-install.log; then
    fail "uv pip install -e . failed (RCA-7-4 + RCA-11). See /tmp/deploy-uv-install.log." 4
  fi
  log "Preflight: prod runtime surface installed successfully"
else
  log "Preflight: no .venv or [project.optional-dependencies] detected — skipping dep install (template uses system Python or containerized runtime)"
fi

# --- 10. Step 3: preflight detect service port conflict (RCA-12 cross-user check) ---
restart_service() {
  log "Restarting $SERVICE_NAME via nohup+setsid (ADR-0047 §Decision.2 — generic, no systemd dependency)"

  # RCA-12 pre-check: detect cross-user port conflict before pkill
  pre_port_pid=""
  if command -v ss >/dev/null 2>&1; then
    pre_line=$(ss -tlnpH "sport = :$DEPLOY_PORT" 2>/dev/null | head -1 || true)
    if [[ -n "$pre_line" ]]; then
      pre_port_pid=$(printf '%s' "$pre_line" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)
    fi
  elif command -v lsof >/dev/null 2>&1; then
    pre_port_pid=$(lsof -ti ":$DEPLOY_PORT" 2>/dev/null | head -1 || true)
  fi
  if [[ -n "$pre_port_pid" ]]; then
    pre_uid=$(ps -o uid= -p "$pre_port_pid" 2>/dev/null | tr -d ' ' || true)
    current_uid=$(id -u)
    if [[ -n "$pre_uid" ]] && [[ "$pre_uid" != "$current_uid" ]]; then
      pre_user=$(ps -o user= -p "$pre_port_pid" 2>/dev/null | tr -d ' ' || echo "uid:$pre_uid")
      fail "port $DEPLOY_PORT is occupied by PID $pre_port_pid owned by user '$pre_user' (uid=$pre_uid), NOT current user '$USER' (uid=$current_uid). Cross-user service stop not possible without sudo (RCA-12). Fix: run as user '$pre_user' OR change \$DEPLOY_PORT to a non-conflicting port." 1
    fi
    log "RCA-12 pre-check: port $DEPLOY_PORT owned by PID $pre_port_pid (uid=$pre_uid, current uid=$current_uid) — same user, kill will work"
  else
    log "RCA-12 pre-check: port $DEPLOY_PORT is free; kill will be a no-op steady-state"
  fi

  # Pre-deploy: stop the existing process (cross-user case already filtered above)
  if [[ -n "$pre_port_pid" ]]; then
    log "Stopping existing process on port $DEPLOY_PORT (PID $pre_port_pid)"
    kill "$pre_port_pid" 2>/dev/null || true
    sleep 1
  fi

  # Validate .venv/bin/uvicorn exists — defense in depth
  if [[ -d "$REPO_DIR/.venv" ]] && [[ ! -x "$REPO_DIR/.venv/bin/uvicorn" ]]; then
    fail ".venv/bin/uvicorn not found or not executable at $REPO_DIR/.venv/bin/uvicorn (RCA-9 regression — preflight did not produce a valid uvicorn binary)" 4
  fi

  # Post-deploy: start the service via nohup+setsid
  log "Starting: nohup setsid .venv/bin/uvicorn $MODULE_PATH --host $DEPLOY_BIND_HOST --port $DEPLOY_PORT (ADR-0047 §Decision.2)"
  if [[ -d "$REPO_DIR/.venv" ]]; then
    nohup setsid "$REPO_DIR/.venv/bin/uvicorn" "$MODULE_PATH" --host "$DEPLOY_BIND_HOST" --port "$DEPLOY_PORT" \
      > /tmp/deploy-uvicorn.log 2>&1 < /dev/null &
  else
    # Fallback: system Python with uvicorn on PATH
    if ! command -v uvicorn >/dev/null 2>&1; then
      fail "uvicorn not on PATH and no .venv/bin/uvicorn — cannot start service" 4
    fi
    nohup setsid uvicorn "$MODULE_PATH" --host "$DEPLOY_BIND_HOST" --port "$DEPLOY_PORT" \
      > /tmp/deploy-uvicorn.log 2>&1 < /dev/null &
  fi
  sleep 2

  # RCA-12 post-check: strict port-PID etimes check
  new_port_pid=""
  if command -v ss >/dev/null 2>&1; then
    new_line=$(ss -tlnpH "sport = :$DEPLOY_PORT" 2>/dev/null | head -1 || true)
    if [[ -n "$new_line" ]]; then
      new_port_pid=$(printf '%s' "$new_line" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)
    fi
  elif command -v lsof >/dev/null 2>&1; then
    new_port_pid=$(lsof -ti ":$DEPLOY_PORT" 2>/dev/null | head -1 || true)
  fi
  if [[ -z "$new_port_pid" ]]; then
    fail "RCA-12 post-check: no process is bound to port $DEPLOY_PORT after restart. See /tmp/deploy-uvicorn.log for uvicorn output." 1
  fi
  new_etimes=$(ps -o etimes= -p "$new_port_pid" 2>/dev/null | tr -d ' ' || echo "")
  if [[ -z "$new_etimes" ]] || ! [[ "$new_etimes" =~ ^[0-9]+$ ]]; then
    fail "RCA-12 post-check: cannot determine etimes for PID $new_port_pid on port $DEPLOY_PORT" 1
  fi
  if [[ "$new_etimes" -gt 60 ]]; then
    new_user=$(ps -o user= -p "$new_port_pid" 2>/dev/null | tr -d ' ' || echo "uid:?")
    fail "RCA-12 post-check: port $DEPLOY_PORT is bound by PID $new_port_pid (user=$new_user, etimes=${new_etimes}s) — NOT our just-started uvicorn. Cross-user scenario recurring." 1
  fi
  log "RCA-12 post-check: port $DEPLOY_PORT owned by PID $new_port_pid (etimes=${new_etimes}s, recent) — service restart verified"
}

restart_service

# --- 11. Step 4: smoke test (DEPLOY-003 / ADR-0027 §Decision.3) ---
log "Smoke test: GET $HEALTHZ_URL (expecting git_sha=$GITHUB_SHA)"
smoke_ok="false"
for attempt in $(seq 1 "$SMOKE_ATTEMPTS"); do
  if body=$(curl -fsS --max-time "$HEALTHZ_TIMEOUT_SEC" "$HEALTHZ_URL" 2>/dev/null); then
    # Extract git_sha defensively (JSON parser could fail if body is malformed)
    actual_sha=$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("git_sha", "") or "")
except Exception:
    print("")
' 2>/dev/null || true)
    if [[ "$actual_sha" == "$GITHUB_SHA" ]]; then
      log "Smoke test PASSED on attempt $attempt: git_sha matches GITHUB_SHA"
      smoke_ok="true"
      break
    fi
    log "Smoke test attempt $attempt: git_sha mismatch (got=$actual_sha want=$GITHUB_SHA)"
  else
    log "Smoke test attempt $attempt: curl failed (service not up yet?)"
  fi
  sleep "$SMOKE_RETRY_DELAY_SEC"
done

if [[ "$smoke_ok" == "true" ]]; then
  exit 0
fi

# --- 12. Step 5: rollback (ADR-0027 §Decision.3 auto-rollback) ---
log "Smoke test FAILED after $SMOKE_ATTEMPTS attempts; rolling back to HEAD@{1}"
git reset --hard HEAD@{1}
restart_service

# --- 13. Step 6: retry smoke test once; if this ALSO fails, page owner ---
log "Retry smoke test after rollback"
retry_ok="false"
if body=$(curl -fsS --max-time "$HEALTHZ_TIMEOUT_SEC" "$HEALTHZ_URL" 2>/dev/null); then
  log "Post-rollback smoke test PASSED (deploy rolled back to a working prior SHA)"
  retry_ok="true"
fi

if [[ "$retry_ok" == "true" ]]; then
  log "Returning exit 1: deploy failed but rollback succeeded; workflow should page owner"
  exit 1
fi

# --- 14. Step 7: double-failure: page owner (per ADR-0027 §Decision.3) ---
log "Double-failure: smoke test failed BEFORE and AFTER rollback; paging owner"
notify_path="$REPO_DIR/scripts/notify.sh"
if [[ -x "$notify_path" ]]; then
  "$notify_path" -l human "[DEPLOY] $SERVICE_NAME rollback FAILED on $ACTUAL_HOSTNAME — manual intervention required. Expected SHA=$GITHUB_SHA. See workflow: $GITHUB_SHA" || true
else
  log "WARN: $notify_path not found or not executable; cannot page owner via notify.sh"
fi
exit 2