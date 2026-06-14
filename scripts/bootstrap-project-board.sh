#!/usr/bin/env bash
# bootstrap-project-board.sh — idempotent GitHub Projects v2 board provisioning.
#
# Per the dev-studio CLAUDE.md contract: agent workflow uses the Projects v2
# board as the single source of truth for story flow:
#
#   Backlog → Ready → In Progress → In Review → Done
#
# This script creates that board, links it to the current repo, ensures the
# Status field has all 5 columns, and adds every existing issue to the board
# (set to Backlog by default).
#
# What this script does NOT do (GitHub API limitation — Projects v2 workflow
# management has no public mutation API yet, see community discussion #194509):
#   - Toggle "Auto-add to project" workflow
#   - Toggle "Item closed → Done" workflow
#   - Toggle label-based status workflows
# These remain a 30-second one-time manual step per project; see README.
#
# Usage:
#   bootstrap-project-board.sh                  # uses current repo
#   bootstrap-project-board.sh owner/name       # explicit repo
#
# Exit codes:
#   0 — success
#   2 — preflight failure (missing tool / unauthenticated)
#   3 — auth lacks `project` scope (soft skip; init.sh continues)
#   4 — GraphQL / API failure
#
# Idempotency:
#   Safe to re-run. If the board already exists with the expected title,
#   the script reuses it. Status field options are reconciled (missing
#   options are added; extra options are left alone). Existing items are
#   not re-added.

set -euo pipefail

# ---------- shared helpers ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_RESET=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

log()  { printf '%s[board]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[fail]%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; }

# ---------- preflight ----------
REPO="${1:-}"
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" || {
    err "Cannot determine repo. Pass owner/name or run inside a git repo."
    exit 2
  }
fi

OWNER="${REPO%/*}"
REPO_NAME="${REPO#*/}"
BOARD_TITLE="${BOARD_TITLE:-${REPO_NAME} board}"
STATUS_OPTIONS=("Backlog" "Ready" "In Progress" "In Review" "Done")

command -v gh >/dev/null 2>&1 || { err "gh CLI not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { err "jq not found"; exit 2; }

# Check 'project' scope. gh stores scopes via 'gh auth status'.
# If missing, we soft-fail (exit 3) so dev-studio-init.sh can continue.
if ! gh auth status 2>&1 | grep -qE "Token scopes.*'?project'?"; then
  warn "GitHub token lacks the 'project' scope — board bootstrap skipped."
  warn "To enable, run:  gh auth refresh -s project,read:project"
  warn "Then re-run:     scripts/bootstrap-project-board.sh"
  exit 3
fi

log "target repo:   $REPO"
log "board title:   $BOARD_TITLE"

# ---------- resolve owner node ID ----------
# Projects v2 are owned by either a user or an org. We resolve the owner's
# node ID from the repo's owner.
OWNER_TYPE="$(gh api "users/$OWNER" --jq '.type' 2>/dev/null || echo "")"
case "$OWNER_TYPE" in
  User)         OWNER_QUERY='query($login:String!){ user(login:$login){ id } }';         OWNER_PATH='.data.user.id' ;;
  Organization) OWNER_QUERY='query($login:String!){ organization(login:$login){ id } }'; OWNER_PATH='.data.organization.id' ;;
  *)            err "Cannot determine owner type for '$OWNER' (got: '$OWNER_TYPE')"; exit 4 ;;
esac

OWNER_ID="$(gh api graphql -f query="$OWNER_QUERY" -f login="$OWNER" --jq "$OWNER_PATH" 2>/dev/null || true)"
[ -n "$OWNER_ID" ] || { err "Failed to resolve owner node ID for $OWNER"; exit 4; }

# ---------- find or create the board ----------
# List existing projects for this owner; reuse if title matches.
LIST_QUERY='
  query($login:String!){
    '"$( [ "$OWNER_TYPE" = "User" ] && echo "user" || echo "organization")"'(login:$login){
      projectsV2(first:100){ nodes { id title number } }
    }
  }'

EXISTING="$(gh api graphql -f query="$LIST_QUERY" -f login="$OWNER" \
              --jq ".data.$( [ "$OWNER_TYPE" = "User" ] && echo "user" || echo "organization").projectsV2.nodes[] | select(.title==\"$BOARD_TITLE\")" \
              2>/dev/null || true)"

if [ -n "$EXISTING" ]; then
  PROJECT_ID="$(echo "$EXISTING" | jq -r '.id' | head -n1)"
  PROJECT_NUMBER="$(echo "$EXISTING" | jq -r '.number' | head -n1)"
  ok "board exists (#$PROJECT_NUMBER) — reusing"
else
  log "creating board '$BOARD_TITLE'"
  CREATE_OUT="$(gh api graphql -f query='
    mutation($ownerId:ID!, $title:String!){
      createProjectV2(input:{ownerId:$ownerId, title:$title}){
        projectV2 { id number }
      }
    }' -f ownerId="$OWNER_ID" -f title="$BOARD_TITLE" 2>&1)" || {
      err "createProjectV2 failed:"
      echo "$CREATE_OUT" >&2
      exit 4
    }
  PROJECT_ID="$(echo "$CREATE_OUT" | jq -r '.data.createProjectV2.projectV2.id')"
  PROJECT_NUMBER="$(echo "$CREATE_OUT" | jq -r '.data.createProjectV2.projectV2.number')"
  ok "board created (#$PROJECT_NUMBER)"
fi

# ---------- link board to repo ----------
# linkProjectV2ToRepository wires the project to the repo so that
# `gh project item-add` works without explicit project-id from inside the repo
# and so the repo's Projects tab shows the board.
REPO_ID="$(gh api "repos/$REPO" --jq '.node_id' 2>/dev/null || true)"
[ -n "$REPO_ID" ] || { err "Failed to resolve repo node ID for $REPO"; exit 4; }

LINK_OUT="$(gh api graphql -f query='
  mutation($projectId:ID!, $repoId:ID!){
    linkProjectV2ToRepository(input:{projectId:$projectId, repositoryId:$repoId}){
      repository { id }
    }
  }' -f projectId="$PROJECT_ID" -f repoId="$REPO_ID" 2>&1 || true)"

if echo "$LINK_OUT" | grep -q '"errors"'; then
  # Already linked is fine; surface anything else.
  if echo "$LINK_OUT" | grep -qiE "already linked|already exists"; then
    ok "board already linked to repo"
  else
    warn "linkProjectV2ToRepository returned errors:"
    echo "$LINK_OUT" | jq '.errors // .' 2>/dev/null >&2 || echo "$LINK_OUT" >&2
    # Non-fatal: items can still be added even if linking failed.
  fi
else
  ok "board linked to repo"
fi

# ---------- reconcile Status field options ----------
# Every Projects v2 board has a default 'Status' single-select field with
# 3 options (Todo, In Progress, Done). We need 5: Backlog, Ready, In Progress,
# In Review, Done. We discover what's there and add only what's missing.
FIELDS_OUT="$(gh api graphql -f query='
  query($projectId:ID!){
    node(id:$projectId){
      ... on ProjectV2 {
        fields(first:50){
          nodes {
            __typename
            ... on ProjectV2SingleSelectField { id name options { id name } }
            ... on ProjectV2Field { id name }
          }
        }
      }
    }
  }' -f projectId="$PROJECT_ID" 2>&1)"

STATUS_FIELD_ID="$(echo "$FIELDS_OUT" \
  | jq -r '.data.node.fields.nodes[] | select(.__typename=="ProjectV2SingleSelectField" and .name=="Status") | .id')"

if [ -z "$STATUS_FIELD_ID" ] || [ "$STATUS_FIELD_ID" = "null" ]; then
  err "Could not find Status single-select field on the board."
  err "Output:"
  echo "$FIELDS_OUT" >&2
  exit 4
fi

# Collect current Status option names.
EXISTING_OPTIONS="$(echo "$FIELDS_OUT" \
  | jq -r '.data.node.fields.nodes[] | select(.name=="Status") | .options[].name')"

# Reconcile: add missing options.
# Note: updateProjectV2Field with singleSelectOptions REPLACES the full list,
# so we must include ALL desired options (existing + new) in one mutation,
# in our canonical order. Color is required by the schema (otherwise the
# default 'GRAY' is used — fine for us).
DESIRED_JSON='['
first=1
for opt in "${STATUS_OPTIONS[@]}"; do
  [ $first -eq 1 ] || DESIRED_JSON+=','
  first=0
  DESIRED_JSON+="{\"name\":\"$opt\",\"color\":\"GRAY\",\"description\":\"\"}"
done
DESIRED_JSON+=']'

# Only mutate if the set differs (idempotency + avoid pointless writes).
NEEDS_UPDATE=0
for opt in "${STATUS_OPTIONS[@]}"; do
  if ! echo "$EXISTING_OPTIONS" | grep -qxF "$opt"; then
    NEEDS_UPDATE=1
    break
  fi
done

if [ "$NEEDS_UPDATE" = "1" ]; then
  log "reconciling Status options to: ${STATUS_OPTIONS[*]}"
  UPDATE_OUT="$(gh api graphql -f query='
    mutation($fieldId:ID!, $options:[ProjectV2SingleSelectFieldOptionInput!]!){
      updateProjectV2Field(input:{fieldId:$fieldId, singleSelectOptions:$options}){
        projectV2Field {
          __typename
          ... on ProjectV2SingleSelectField { id name options { name } }
        }
      }
    }' -f fieldId="$STATUS_FIELD_ID" -f options="$DESIRED_JSON" 2>&1 || true)"

  if echo "$UPDATE_OUT" | grep -q '"errors"'; then
    err "updateProjectV2Field failed:"
    echo "$UPDATE_OUT" | jq '.errors // .' 2>/dev/null >&2 || echo "$UPDATE_OUT" >&2
    exit 4
  fi
  ok "Status options updated"
else
  ok "Status options already match (no update needed)"
fi

# ---------- add all existing issues to the board ----------
# Idempotency: gh project item-add returns success if the item is already on
# the board (it just re-adds and reuses the existing item). So we can call it
# blindly per issue.
ISSUE_NUMBERS="$(gh issue list --repo "$REPO" --state all --limit 500 --json number --jq '.[].number' 2>/dev/null || true)"

if [ -z "$ISSUE_NUMBERS" ]; then
  ok "no existing issues to add"
else
  ADDED=0
  while IFS= read -r num; do
    [ -z "$num" ] && continue
    ISSUE_URL="https://github.com/$REPO/issues/$num"
    gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" --url "$ISSUE_URL" >/dev/null 2>&1 \
      && ADDED=$((ADDED+1)) || warn "could not add issue #$num"
  done <<< "$ISSUE_NUMBERS"
  ok "added $ADDED issue(s) to the board"
fi

# ---------- done ----------
BOARD_URL="https://github.com/users/$OWNER/projects/$PROJECT_NUMBER"
[ "$OWNER_TYPE" = "Organization" ] && BOARD_URL="https://github.com/orgs/$OWNER/projects/$PROJECT_NUMBER"

printf '\n'
ok "Board ready:"
printf '  %s\n' "$BOARD_URL"
printf '\n'
printf '%sOne-time manual step (GitHub API limitation, ~30 seconds):%s\n' "$C_BOLD" "$C_RESET"
printf '  1. Open the board (link above) → click ⋯ → Workflows\n'
printf '  2. Enable %s"Auto-add to project"%s for this repository\n' "$C_BOLD" "$C_RESET"
printf '  3. Enable %s"Item closed"%s → Set status: Done\n' "$C_BOLD" "$C_RESET"
printf '  (See README → Project board for screenshots.)\n\n'
