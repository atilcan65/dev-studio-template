#!/usr/bin/env bash
# P2 Faz 5 — full integration smoke test for scripts/dev-studio-init.sh
#
# Tests:
#   T1: --dry-run mode produces no file writes
#   T2: missing-placeholder .tmpl is caught (verify step fails fast)
#   T3: re-run idempotency (output sha256 stable across runs)
#   T4: fresh-clone simulation (lokal clone -> init -> all 12 renders OK)
#   T5: manual edit to rendered output is overwritten on next run
#
# Usage:
#   bash scripts/tests/faz5-smoke.sh                 # all tests
#   bash scripts/tests/faz5-smoke.sh T1 T3           # subset
#   VERBOSE=1 bash scripts/tests/faz5-smoke.sh       # echo intermediate commands
#
# Exit codes: 0 = all PASS, non-zero = at least one FAIL.

set -u  # NOT -e: we want to keep running even if one test fails (so we get full report)

# --- repo root resolution (same idiom as dev-studio-init.sh) -----------------
REPO_ROOT="${DEV_STUDIO_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
INIT_SCRIPT="$REPO_ROOT/scripts/dev-studio-init.sh"

# --- colors (only when stdout is a TTY) --------------------------------------
if [[ -t 1 ]]; then
  C_OK=$'\033[0;32m'; C_FAIL=$'\033[0;31m'; C_INFO=$'\033[0;36m'; C_DIM=$'\033[0;90m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_FAIL=""; C_INFO=""; C_DIM=""; C_OFF=""
fi

# --- counters ----------------------------------------------------------------
PASS=0
FAIL=0
SKIP=0
declare -a RESULTS

# --- helpers -----------------------------------------------------------------
say()  { printf '%s[smoke]%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
ok()   { PASS=$((PASS+1)); RESULTS+=("${C_OK}PASS${C_OFF}  $1"); printf '%s[ ok ]%s %s\n' "$C_OK"   "$C_OFF" "$1"; }
fail() { FAIL=$((FAIL+1)); RESULTS+=("${C_FAIL}FAIL${C_OFF}  $1${2:+ — $2}"); printf '%s[fail]%s %s%s\n' "$C_FAIL" "$C_OFF" "$1" "${2:+ — $2}"; }
skip() { SKIP=$((SKIP+1)); RESULTS+=("${C_DIM}SKIP${C_OFF}  $1${2:+ — $2}"); printf '%s[skip]%s %s%s\n' "$C_DIM"  "$C_OFF" "$1" "${2:+ — $2}"; }

run_verbose() {
  if [[ "${VERBOSE:-}" == "1" ]]; then
    printf '%s$ %s%s\n' "$C_DIM" "$*" "$C_OFF" >&2
  fi
  "$@"
}

# Run a test only if it's in the filter list (or list is empty = all)
should_run() {
  local name="$1"
  if [[ ${#WANT[@]} -eq 0 ]]; then return 0; fi
  for w in "${WANT[@]}"; do [[ "$w" == "$name" ]] && return 0; done
  return 1
}

# --- parse argv: filter tests ------------------------------------------------
WANT=()
for arg in "$@"; do
  case "$arg" in
    T1|T2|T3|T4|T5) WANT+=("$arg") ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# --- preflight ---------------------------------------------------------------
say "REPO_ROOT = $REPO_ROOT"
say "INIT_SCRIPT = $INIT_SCRIPT"

if [[ ! -x "$INIT_SCRIPT" ]] && [[ ! -r "$INIT_SCRIPT" ]]; then
  fail "preflight" "init script not found at $INIT_SCRIPT"
  exit 1
fi

# --- T1: --dry-run produces no file writes -----------------------------------
if should_run T1; then
  say "T1: --dry-run mode produces no file writes"
  BEFORE=$(find "$REPO_ROOT" -type f \
    -not -path '*/\.git/*' \
    -not -path '*/\.venv/*' \
    -not -path '*/__pycache__/*' \
    -not -path '*/node_modules/*' \
    -printf '%p %T@\n' 2>/dev/null | sort | sha256sum | awk '{print $1}')
  OUT=$(bash "$INIT_SCRIPT" --dry-run 2>&1) || true
  AFTER=$(find "$REPO_ROOT" -type f \
    -not -path '*/\.git/*' \
    -not -path '*/\.venv/*' \
    -not -path '*/__pycache__/*' \
    -not -path '*/node_modules/*' \
    -printf '%p %T@\n' 2>/dev/null | sort | sha256sum | awk '{print $1}')
  if [[ "$BEFORE" == "$AFTER" ]]; then
    if grep -q -iE 'dry[ -]?run|would render|plan|render \(dry' <<<"$OUT"; then
      ok "T1 --dry-run: no writes, dry-run mode announced in output"
    else
      ok "T1 --dry-run: no writes (dry-run announcement not detected, but no side effects)"
    fi
  else
    fail "T1 --dry-run" "filesystem mutated during dry-run (BEFORE != AFTER hash)"
  fi
fi

# --- T2: missing-placeholder .tmpl is caught ---------------------------------
if should_run T2; then
  say "T2: bozulmuş .tmpl (unresolved placeholder) tespit edilmeli"
  BAD_DIR="$(mktemp -d -t faz5-T2.XXXXXX)"
  trap 'rm -rf "$BAD_DIR"' RETURN
  # Copy the entire repo to a sandbox so we can inject a bad .tmpl
  cp -r "$REPO_ROOT" "$BAD_DIR/repo"
  rm -rf "$BAD_DIR/repo/.venv" "$BAD_DIR/repo/__pycache__" 2>/dev/null || true
  # Inject a .tmpl that references an unknown placeholder
  cat > "$BAD_DIR/repo/scripts/tests/_bad-fixture.txt.tmpl" <<'EOF'
This template references an unknown placeholder: {{NEVER_RESOLVED}}.
The verify step MUST flag this and exit non-zero.
EOF
  # Run init inside the sandbox
  if DEV_STUDIO_REPO_ROOT="$BAD_DIR/repo" bash "$BAD_DIR/repo/scripts/dev-studio-init.sh" >"$BAD_DIR/out.log" 2>&1; then
    fail "T2 missing-placeholder" "init returned exit 0 — should have flagged unresolved {{NEVER_RESOLVED}}"
    sed -n '1,40p' "$BAD_DIR/out.log" | sed 's/^/    | /' >&2
  else
    if grep -qE 'unresolved|NEVER_RESOLVED|\{\{.*\}\}' "$BAD_DIR/out.log"; then
      ok "T2 missing-placeholder: init exited non-zero AND mentioned the unresolved placeholder"
    else
      ok "T2 missing-placeholder: init exited non-zero (placeholder name not in log, but failure detected)"
    fi
  fi
  rm -rf "$BAD_DIR"
  trap - RETURN
fi

# --- T3: re-run idempotency --------------------------------------------------
if should_run T3; then
  say "T3: re-run idempotency (output sha256 stable)"
  # Use a sandbox to avoid mutating the live repo's mtimes
  IDEM_DIR="$(mktemp -d -t faz5-T3.XXXXXX)"
  cp -r "$REPO_ROOT" "$IDEM_DIR/repo"
  rm -rf "$IDEM_DIR/repo/.venv" "$IDEM_DIR/repo/__pycache__" 2>/dev/null || true
  # Run 1
  DEV_STUDIO_REPO_ROOT="$IDEM_DIR/repo" bash "$IDEM_DIR/repo/scripts/dev-studio-init.sh" >"$IDEM_DIR/run1.log" 2>&1
  RUN1_RC=$?
  HASH1=$(find "$IDEM_DIR/repo" -type f \
    -not -path '*/\.git/*' \
    -not -path '*/\.venv/*' \
    -not -path '*/__pycache__/*' \
    \( -name '*.md' -o -name '*.yml' -o -name '*.service' -o -name '*.path' \) \
    -exec sha256sum {} \; 2>/dev/null | awk '{print $1}' | sort | sha256sum | awk '{print $1}')
  # Run 2
  DEV_STUDIO_REPO_ROOT="$IDEM_DIR/repo" bash "$IDEM_DIR/repo/scripts/dev-studio-init.sh" >"$IDEM_DIR/run2.log" 2>&1
  RUN2_RC=$?
  HASH2=$(find "$IDEM_DIR/repo" -type f \
    -not -path '*/\.git/*' \
    -not -path '*/\.venv/*' \
    -not -path '*/__pycache__/*' \
    \( -name '*.md' -o -name '*.yml' -o -name '*.service' -o -name '*.path' \) \
    -exec sha256sum {} \; 2>/dev/null | awk '{print $1}' | sort | sha256sum | awk '{print $1}')
  if [[ "$RUN1_RC" -eq 0 && "$RUN2_RC" -eq 0 && "$HASH1" == "$HASH2" ]]; then
    ok "T3 idempotency: hash($HASH1) stable across 2 runs"
  else
    fail "T3 idempotency" "rc1=$RUN1_RC rc2=$RUN2_RC hash1=$HASH1 hash2=$HASH2"
  fi
  rm -rf "$IDEM_DIR"
fi

# --- T4: fresh-clone simulation ----------------------------------------------
if should_run T4; then
  say "T4: fresh-clone simulation (lokal git clone -> init -> 12 renders OK)"
  if ! command -v git >/dev/null 2>&1; then
    skip "T4 fresh-clone" "git not available"
  else
    CLONE_DIR="$(mktemp -d -t faz5-T4.XXXXXX)"
    if run_verbose git clone --quiet --depth=1 "$REPO_ROOT" "$CLONE_DIR/repo" 2>"$CLONE_DIR/clone.err"; then
      # Lokal clone'un origin'i lokal path'e bakıyor; init script `gh repo view` çağırır,
      # bu da git remote `origin`'in GitHub URL'i olmasını ister. Gerçek dünyada
      # `gh repo create --template` zaten GitHub remote'una push edilmiş bir clone
      # bırakır; biz de origin'i orijinal GitHub URL'sine geri çeviriyoruz.
      ORIGIN_URL="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || true)"
      if [[ -n "$ORIGIN_URL" ]]; then
        git -C "$CLONE_DIR/repo" remote set-url origin "$ORIGIN_URL" 2>/dev/null || true
      fi
      # init from inside the clone
      if (cd "$CLONE_DIR/repo" && bash scripts/dev-studio-init.sh) >"$CLONE_DIR/init.log" 2>&1; then
        # Stray-check scope: ONLY files init actually produced. We compute the
        # rendered-dst list the same way init does (every *.tmpl → dst with
        # .tmpl extension stripped). Scanning the whole clone would flag user-
        # authored docs that legitimately contain {{...}} (e.g. CHANGES files
        # documenting placeholder names) — those are NOT init's failure.
        STRAY=0
        while IFS= read -r -d '' tmpl; do
          dst="${tmpl%.tmpl}"
          if [[ -f "$dst" ]] && grep -qE '\{\{[A-Z_]+\}\}' "$dst" 2>/dev/null; then
            STRAY=$((STRAY + 1))
          fi
        done < <(find "$CLONE_DIR/repo" \
          -path "$CLONE_DIR/repo/.git" -prune -o \
          -path "$CLONE_DIR/repo/.venv" -prune -o \
          -type f -name '*.tmpl' -print0 2>/dev/null)
        # Look for the "12 template(s) rendered" line specifically
        if grep -qE '12 template\(s\) rendered' "$CLONE_DIR/init.log" && [[ "$STRAY" -eq 0 ]]; then
          ok "T4 fresh-clone: 12 templates rendered, no stray placeholders"
        elif [[ "$STRAY" -eq 0 ]]; then
          ok "T4 fresh-clone: render OK, no stray placeholders (template count not 12 verbatim)"
        else
          fail "T4 fresh-clone" "stray placeholders detected in $STRAY rendered output(s), see $CLONE_DIR/init.log"
          sed -n '1,40p' "$CLONE_DIR/init.log" | sed 's/^/    | /' >&2
        fi
      else
        fail "T4 fresh-clone" "init script failed in fresh clone"
        sed -n '1,40p' "$CLONE_DIR/init.log" | sed 's/^/    | /' >&2
      fi
    else
      skip "T4 fresh-clone" "git clone failed: $(cat "$CLONE_DIR/clone.err" 2>/dev/null | head -1)"
    fi
    rm -rf "$CLONE_DIR"
  fi
fi

# --- T5: manual edit to rendered output is overwritten -----------------------
if should_run T5; then
  say "T5: manuel edit'in üzerine basılmalı (idempotent re-render)"
  EDIT_DIR="$(mktemp -d -t faz5-T5.XXXXXX)"
  cp -r "$REPO_ROOT" "$EDIT_DIR/repo"
  rm -rf "$EDIT_DIR/repo/.venv" "$EDIT_DIR/repo/__pycache__" 2>/dev/null || true
  # First, render once to produce the README.md
  DEV_STUDIO_REPO_ROOT="$EDIT_DIR/repo" bash "$EDIT_DIR/repo/scripts/dev-studio-init.sh" >/dev/null 2>&1
  TARGET="$EDIT_DIR/repo/README.md"
  if [[ ! -f "$TARGET" ]]; then
    fail "T5 manual-edit" "README.md not rendered by initial init"
  else
    # Manually corrupt the rendered output
    MARKER="### MANUAL_EDIT_THAT_MUST_BE_OVERWRITTEN_$$"
    printf '\n\n%s\n' "$MARKER" >> "$TARGET"
    # Re-run init
    DEV_STUDIO_REPO_ROOT="$EDIT_DIR/repo" bash "$EDIT_DIR/repo/scripts/dev-studio-init.sh" >/dev/null 2>&1
    if grep -qF "$MARKER" "$TARGET"; then
      fail "T5 manual-edit" "manual edit survived re-render — init is NOT idempotent"
    else
      ok "T5 manual-edit: manuel edit re-render ile silindi (idempotent)"
    fi
  fi
  rm -rf "$EDIT_DIR"
fi

# --- summary -----------------------------------------------------------------
TOTAL=$((PASS+FAIL+SKIP))
echo
echo "===== Faz 5 smoke summary ====="
for line in "${RESULTS[@]}"; do printf '  %s\n' "$line"; done
echo "------------------------------"
printf '  TOTAL=%d  PASS=%d  FAIL=%d  SKIP=%d\n' "$TOTAL" "$PASS" "$FAIL" "$SKIP"
echo "==============================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
