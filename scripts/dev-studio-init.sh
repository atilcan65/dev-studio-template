#!/usr/bin/env bash
# dev-studio-init.sh — Render .tmpl templates into final working files.
#
# This is the **first command** to run after cloning a new project from the
# dev-studio-template repository. It collects environment values from the
# system (gh CLI, git config) and renders every `*.tmpl` file in the repo
# into its final form (same path, .tmpl extension stripped).
#
# Rendered outputs are .gitignore'd by design — every clone runs this once.
#
# Usage:
#   bash scripts/dev-studio-init.sh           # render everything
#   bash scripts/dev-studio-init.sh --dry-run # show what would be rendered, no writes
#   bash scripts/dev-studio-init.sh --verbose # extra diagnostic output
#
# Exit codes:
#   0  success
#   1  preflight failure (gh/git missing, not authenticated, etc.)
#   2  template render failure
#
# Idempotent: always renders fresh. Manual edits to rendered outputs are lost.
# (They are gitignored, so don't edit them — edit the `.tmpl` and re-run.)

set -euo pipefail

# --- Configuration --------------------------------------------------------

# Auto-detect repo root from this script's location.
REPO_ROOT="${DEV_STUDIO_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

DRY_RUN=0
VERBOSE=0

# Paths of rendered output files (populated by render_all, consumed by verify).
# Using a global array so verify scans ONLY what init produced — not user files
# elsewhere in the repo that may contain literal {{...}} for unrelated reasons
# (e.g. test fixtures, Jinja docs, this script's own sed lines).
RENDERED_PATHS=()

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help)
      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

# --- Pretty printing ------------------------------------------------------

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_BLUE=$'\033[34m'

log()  { printf '%s[init]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf '%s[fail]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit "${2:-1}"; }
dbg()  { [ "$VERBOSE" = "1" ] && printf '%s[dbg ]%s %s\n' "$C_BOLD" "$C_RESET" "$*"; return 0; }

# --- Preflight: required tools and authentication -------------------------

preflight() {
  log "preflight checks"

  command -v gh  >/dev/null 2>&1 || fail "gh CLI not found. Install: https://cli.github.com/"
  command -v git >/dev/null 2>&1 || fail "git not found."
  command -v sed >/dev/null 2>&1 || fail "sed not found."

  # gh auth status: do not echo any token; just check exit code.
  if ! gh auth status >/dev/null 2>&1; then
    fail "gh CLI is not authenticated. Run: gh auth login"
  fi

  [ -d "$REPO_ROOT/.git" ] || fail "REPO_ROOT is not a git repository: $REPO_ROOT"

  ok "preflight passed"
}

# --- Resolve placeholder values from the system ---------------------------

resolve_values() {
  log "resolving placeholder values"

  # GitHub login (handle). Fails if gh not authenticated (preflight catches).
  GITHUB_OWNER="$(gh api user --jq .login 2>/dev/null)" \
    || fail "could not resolve {{GITHUB_OWNER}} via 'gh api user'"

  # Current repo name from gh (works because we're inside the repo).
  GITHUB_REPO="$(gh repo view --json name --jq .name 2>/dev/null)" \
    || fail "could not resolve {{GITHUB_REPO}} via 'gh repo view'. Is this repo pushed to GitHub yet?"

  # Human display name from git config.
  HUMAN_OWNER_NAME="$(git -C "$REPO_ROOT" config user.name 2>/dev/null || true)"
  if [ -z "$HUMAN_OWNER_NAME" ]; then
    fail "{{HUMAN_OWNER_NAME}} is empty. Set: git config --global user.name 'Your Name'"
  fi

  # REPO_ROOT already resolved at the top.

  # Per-project derived values (ADR-0010).
  PROJECT_NAME="${DEV_STUDIO_PROJECT_NAME:-$(basename "$REPO_ROOT")}"
  HEARTBEAT_BASE="${DEV_STUDIO_HEARTBEAT_BASE:-/var/log/dev-studio}"
  HEARTBEAT_DIR="$HEARTBEAT_BASE/$PROJECT_NAME"

  printf '\n%s  Placeholder values resolved:%s\n' "$C_BOLD" "$C_RESET"
  printf '    REPO_ROOT        = %s\n' "$REPO_ROOT"
  printf '    GITHUB_OWNER     = %s\n' "$GITHUB_OWNER"
  printf '    GITHUB_REPO      = %s\n' "$GITHUB_REPO"
  printf '    HUMAN_OWNER_NAME = %s\n' "$HUMAN_OWNER_NAME"
  printf '    PROJECT_NAME     = %s\n' "$PROJECT_NAME"
  printf '    HEARTBEAT_DIR    = %s\n\n' "$HEARTBEAT_DIR"
}

# --- Ensure PROJECT_TOKEN secret is set on the repo (ADR-0014) ------------
#
# The status-label-to-board.yml workflow needs a PAT with `repo` + `project`
# scopes to mutate the Projects v2 board. Default GITHUB_TOKEN can't do this
# (no `project` scope, no `permissions:` key to grant it).
#
# Flow:
#   1. If PROJECT_TOKEN env var is set, use it directly (CI / scripted runs).
#   2. Otherwise prompt the user interactively (read -s, no echo).
#   3. Validate format (ghp_* classic or github_pat_* fine-grained).
#   4. Write to repo secret via `gh secret set` (idempotent: overwrites).
#
# Soft-fails only on missing repo (which preflight should have caught); a
# missing/invalid token is a hard fail — the rest of init is meaningless
# without it because the board sync workflow will fail on first issue.
#
# Skip in dry-run mode (don't mutate user repo secrets during a preview).

ensure_project_token() {
  if [ "$DRY_RUN" = "1" ]; then
    log "skipping PROJECT_TOKEN secret setup (dry-run)"
    return 0
  fi

  # Test harnesses can opt out entirely (e2e pilots that don't exercise board sync).
  if [ "${DEV_STUDIO_SKIP_PROJECT_TOKEN:-0}" = "1" ]; then
    log "skipping PROJECT_TOKEN secret setup (DEV_STUDIO_SKIP_PROJECT_TOKEN=1)"
    return 0
  fi

  log "ensuring PROJECT_TOKEN repo secret (ADR-0014)"

  local token="${PROJECT_TOKEN:-}"
  if [ -z "$token" ]; then
    # Interactive prompt. -s suppresses echo so the token never lands in the
    # terminal scrollback or any session-capture logs.
    printf '\n%sPROJECT_TOKEN required for Projects v2 board sync (ADR-0014).%s\n' "$C_BOLD" "$C_RESET"
    printf '  Create at: https://github.com/settings/tokens (classic)\n'
    printf '  Required scopes: %srepo%s + %sproject%s\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '  Tip: export PROJECT_TOKEN=ghp_... before re-running to skip this prompt.\n\n'
    printf 'Paste PROJECT_TOKEN (hidden): '
    # Read with no echo. </dev/tty so this works even if stdin is piped.
    if [ -r /dev/tty ]; then
      IFS= read -rs token </dev/tty || true
    else
      IFS= read -rs token || true
    fi
    printf '\n'
  fi

  if [ -z "$token" ]; then
    fail "PROJECT_TOKEN is empty. Set it via env var or paste at the prompt. See ADR-0014."
  fi

  # Format validation: classic PATs start ghp_, fine-grained start github_pat_.
  # We recommend classic (template-grade reuse) but accept fine-grained for
  # forward compatibility. Anything else is likely a paste error.
  case "$token" in
    ghp_*|github_pat_*) : ;;
    *)
      fail "PROJECT_TOKEN format unrecognised (expected ghp_* or github_pat_*). Aborting before secret write."
      ;;
  esac

  # Write the secret. `gh secret set --body -` reads from stdin so the token
  # never appears in process args (visible via ps).
  if printf '%s' "$token" | gh secret set PROJECT_TOKEN \
       --body - \
       --repo "$GITHUB_OWNER/$GITHUB_REPO" >/dev/null 2>&1; then
    ok "PROJECT_TOKEN secret written to $GITHUB_OWNER/$GITHUB_REPO"
  else
    fail "failed to write PROJECT_TOKEN secret. Check gh auth status and repo permissions."
  fi

  # --- Live health-check (ADR-0014 §3.4) ----------------------------------
  # The secret was accepted by GitHub's secrets API, but that only validates
  # storage — not that the token itself is alive, unrevoked, or scoped
  # correctly. A workflow that uses a dead PROJECT_TOKEN will fail with
  # "Bad credentials" (HTTP 401) at the GraphQL ProjectV2 mutation, which
  # surfaces as a board-sync failure on the very first Vision issue. We
  # caught this once and lost 30 minutes debugging. Verify here, fast-fail
  # early with a precise error before any other init work proceeds.
  log "verifying PROJECT_TOKEN with live GitHub API ping"
  local http_code
  http_code="$(curl -fsS -o /dev/null -w '%{http_code}' \
    --max-time 10 \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/user 2>/dev/null || echo "000")"

  case "$http_code" in
    200)
      ok "PROJECT_TOKEN live auth check passed (HTTP 200)"
      ;;
    401)
      fail "PROJECT_TOKEN rejected by GitHub (HTTP 401 Bad credentials). Token may be revoked, expired, or malformed. Generate a fresh classic PAT with repo+project scopes and re-run. See ADR-0014 §3.4."
      ;;
    403)
      fail "PROJECT_TOKEN authenticated but lacks scope (HTTP 403). Ensure the classic PAT has at minimum 'repo' and 'project' scopes. See ADR-0014 §3.1."
      ;;
    000)
      fail "PROJECT_TOKEN health check could not reach GitHub (network error or timeout). Check connectivity to api.github.com."
      ;;
    *)
      fail "PROJECT_TOKEN health check returned unexpected HTTP $http_code. Inspect token and re-run. See ADR-0014 §3.4."
      ;;
  esac

  # Clear token from local shell var (defense-in-depth; env var still exists).
  unset token
}

# --- Render a single .tmpl file -------------------------------------------
#
# render_one <source.tmpl> <destination>
#
# Uses sed with `|` as delimiter to avoid escaping path slashes.
# Values are expected to be ASCII-safe (GitHub usernames, repo names,
# absolute paths). Names with `|` are an extreme edge case; sed would
# break — but git config user.name is unlikely to contain it.

render_one() {
  local src="$1"
  local dst="$2"

  [ -f "$src" ] || { warn "source missing: $src (skipped)"; return 0; }

  if [ "$DRY_RUN" = "1" ]; then
    printf '    %s[dry]%s %s -> %s\n' "$C_YELLOW" "$C_RESET" "$src" "$dst"
    return 0
  fi

  mkdir -p "$(dirname "$dst")"
  sed -e "s|{{REPO_ROOT}}|${REPO_ROOT}|g" \
      -e "s|{{GITHUB_OWNER}}|${GITHUB_OWNER}|g" \
      -e "s|{{GITHUB_REPO}}|${GITHUB_REPO}|g" \
      -e "s|{{HUMAN_OWNER_NAME}}|${HUMAN_OWNER_NAME}|g" \
      -e "s|{{PROJECT_NAME}}|${PROJECT_NAME}|g" \
      -e "s|{{HEARTBEAT_DIR}}|${HEARTBEAT_DIR}|g" \
      "$src" > "$dst"

  # Preserve executable bit if source had it (relevant for shell templates).
  if [ -x "$src" ]; then
    chmod +x "$dst"
  fi

  # Remove the .tmpl source after successful render. Template-grade contract:
  # rendered repos should contain ONLY final files — leftover .tmpl files are
  # confusing for downstream consumers and break post-init smoke tests that
  # assert "no .tmpl present". DRY_RUN skips this (we already returned above).
  rm -f "$src"

  dbg "rendered: $src -> $dst (source removed)"
}

# --- Render all .tmpl files in the repo -----------------------------------

render_all() {
  log "rendering templates"

  local count=0
  local failed=0

  # Find every *.tmpl file under REPO_ROOT, excluding .git/ and node_modules-like dirs.
  # Skip status-label-to-board.yml.tmpl: it needs {{GITHUB_PROJECT_NUMBER}} which is
  # not known until bootstrap-project-board.sh creates the board (ADR-0013). The
  # board bootstrap script renders that template itself as a post-step.
  while IFS= read -r -d '' tmpl; do
    case "$tmpl" in
      */.github/workflows/status-label-to-board.yml.tmpl)
        log "deferring $(basename "$tmpl") render to bootstrap-project-board.sh (ADR-0013)"
        continue
        ;;
    esac
    local dst="${tmpl%.tmpl}"
    if render_one "$tmpl" "$dst"; then
      count=$((count + 1))
      # Track dst for verify() — only files we actually produced get scanned.
      RENDERED_PATHS+=("$dst")
    else
      failed=$((failed + 1))
    fi
  done < <(find "$REPO_ROOT" \
             -path "$REPO_ROOT/.git" -prune -o \
             -path "$REPO_ROOT/node_modules" -prune -o \
             -path "$REPO_ROOT/.tmux-bootstrap" -prune -o \
             -path "$REPO_ROOT/scripts/.tmux-bootstrap" -prune -o \
             -type f -name "*.tmpl" -print0)

  if [ "$DRY_RUN" = "1" ]; then
    ok "[dry-run] $count template(s) would be rendered"
  else
    ok "$count template(s) rendered"
  fi

  [ "$failed" -eq 0 ] || fail "$failed template(s) failed to render" 2
}

# --- Post-render verification: ensure no unresolved placeholders ----------

verify() {
  [ "$DRY_RUN" = "1" ] && return 0

  log "verifying rendered outputs"

  # Scope: scan ONLY files we just rendered. This avoids false positives from
  # user-authored files (test fixtures, scripts, docs/decisions/, third-party
  # packages) that may legitimately contain {{...}} strings unrelated to our
  # placeholder set. The contract is: a render is successful iff every dst
  # produced by render_all has no remaining {{UPPER_SNAKE}} markers.
  if [ "${#RENDERED_PATHS[@]}" -eq 0 ]; then
    ok "no rendered outputs to verify (0 .tmpl files found)"
    return 0
  fi

  local stragglers
  stragglers=$(grep -lE "\{\{[A-Z_]+\}\}" "${RENDERED_PATHS[@]}" 2>/dev/null || true)

  if [ -n "$stragglers" ]; then
    warn "Unresolved placeholders found in rendered files:"
    echo "$stragglers" | sed 's|^|      |'
    warn "Check the .tmpl source files for unknown placeholders."
    # Template-grade contract: an unresolved placeholder is a render failure.
    # Exit 2 matches the documented \"template render failure\" code in the
    # script header. Silent-failure prevention is part of the template's
    # core guarantees — do NOT downgrade this back to a warning.
    exit 2
  fi

  ok "no unresolved placeholders"
}

# --- Summary --------------------------------------------------------------

summary() {
  printf '\n%s===== dev-studio-init summary =====%s\n' "$C_BOLD" "$C_RESET"
  printf '  repo:    %s/%s\n' "$GITHUB_OWNER" "$GITHUB_REPO"
  printf '  owner:   %s\n' "$HUMAN_OWNER_NAME"
  printf '  root:    %s\n' "$REPO_ROOT"
  [ "$DRY_RUN" = "1" ] \
    && printf '  mode:    %sDRY-RUN%s (no files written)\n' "$C_YELLOW" "$C_RESET" \
    || printf '  mode:    %srender%s\n' "$C_GREEN" "$C_RESET"
  printf '\nNext steps:\n'
  printf '  1) bash scripts/dev-studio-start.sh start    # launch tmux session\n'
  printf '  2) Open a GitHub issue with label "agent:product-manager" to feed your vision\n'
  printf '     (watchers are already running per-project via systemd; see ADR-0010)\n\n'
}

# --- Project board bootstrap ---------------------------------------------
# Provisions the GitHub Projects v2 board (5 columns) and adds every existing
# issue to it. Soft-fails (does not abort init) if the gh token lacks the
# 'project' scope — board can be added later by running the script directly.
bootstrap_board() {
  [ "$DRY_RUN" = "1" ] && { log "skipping board bootstrap (dry-run)"; return 0; }

  # Test harnesses (e.g. e2e-pilot.sh) can opt out by setting
  # DEV_STUDIO_SKIP_BOARD=1 to avoid creating Projects v2 boards under the
  # pilot's user account and exhausting the 'project' scope on every run.
  if [ "${DEV_STUDIO_SKIP_BOARD:-0}" = "1" ]; then
    log "skipping board bootstrap (DEV_STUDIO_SKIP_BOARD=1)"
    return 0
  fi

  local script="$REPO_ROOT/scripts/bootstrap-project-board.sh"
  if [ ! -x "$script" ]; then
    warn "bootstrap-project-board.sh not found or not executable — skipping"
    return 0
  fi

  log "provisioning project board"
  # Use the env-resolved repo so this works regardless of cwd.
  if "$script" "$GITHUB_OWNER/$GITHUB_REPO"; then
    ok "project board ready"
  else
    local rc=$?
    if [ "$rc" -eq 3 ]; then
      # Soft-skip: missing 'project' scope. Surface guidance but continue.
      warn "board bootstrap skipped (gh token lacks 'project' scope)"
      warn "Run later: gh auth refresh -s project,read:project && scripts/bootstrap-project-board.sh"
    else
      warn "board bootstrap failed (exit $rc) — continuing init"
      warn "Re-run manually: scripts/bootstrap-project-board.sh"
    fi
  fi
}

# --- Per-project systemd watcher install ---------------------------------
# Installs 5 systemd --user watcher instances scoped to this project so they
# survive tmux/Claude exits and don't collide with other projects' watchers.
# Soft-fails if systemd --user is unavailable (e.g. container CI) so the rest
# of init still succeeds and pane-bootstrap falls back to nohup mode.
# Per ADR-0010.
install_systemd_watchers() {
  [ "$DRY_RUN" = "1" ] && { log "skipping systemd install (dry-run)"; return 0; }

  if [ "${DEV_STUDIO_SKIP_SYSTEMD:-0}" = "1" ]; then
    log "skipping systemd install (DEV_STUDIO_SKIP_SYSTEMD=1)"
    return 0
  fi

  if ! systemctl --user --no-pager show-environment >/dev/null 2>&1; then
    warn "systemd --user not available; pane-bootstrap will use nohup fallback"
    return 0
  fi

  local script="$REPO_ROOT/scripts/install/dev-studio-install-systemd.sh"
  if [ ! -x "$script" ]; then
    warn "install-systemd.sh not found or not executable — skipping"
    return 0
  fi

  log "installing per-project systemd watchers"
  if PROJECT_NAME="$(basename "$REPO_ROOT")" REPO_ROOT="$REPO_ROOT" "$script"; then
    ok "systemd watchers installed"
  else
    warn "systemd install failed (soft-fail) — pane-bootstrap will use nohup fallback"
    warn "Re-run manually: bash $script"
  fi
}

# --- Main -----------------------------------------------------------------

main() {
  preflight
  resolve_values
  ensure_project_token
  render_all
  verify
  bootstrap_board
  install_systemd_watchers
  summary
}

main "$@"
