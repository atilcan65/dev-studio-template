# Project Context — for all agents

> Read this file at the start of every session. It is the single source of truth for product, team, and process context.

## Product
- **Name**: atilprojects
- **Vision**: <one paragraph from `docs/product/vision.md`>
- **Current sprint**: see `docs/sprints/current/plan.md`
- **Source of truth for backlog**: GitHub Project board (Projects v2)

## Team (5 agents + 1 human)
| Role | Who | Soul file |
|---|---|---|
| Human owner | atil can | — |
| Orchestrator | Claude Code / MiniMax-M3 | `.claude/agents/orchestrator.md` |
| Product Manager | Claude Code / MiniMax-M3 | `.claude/agents/product-manager.md` |
| Architect | Claude Code / MiniMax-M3 | `.claude/agents/architect.md` |
| Developer | Claude Code / MiniMax-M3 | `.claude/agents/developer.md` |
| Tester | Claude Code / MiniMax-M3 | `.claude/agents/tester.md` |
| Test Runner / Incident Bot | Codex CLI / gpt-5.5 | (separate process, see `scripts/codex-runner.sh`) |

## Process
- **Scrum** with 2-week sprints.
- **GitHub Projects v2** is the board. Columns: Backlog → Ready → In Progress → In Review → Done.
- **All PRs are draft** until Tester signoff + human approval.
- **Branch protection** on `main`: no direct push (enforced by local pre-push hook + human discipline), 1 human approval required, CI green.
- **Conventional commits**: `feat(scope): ...`, `fix(scope): ...`, `chore(scope): ...`.
- **Daily standup** at 09:00 Europe/Istanbul (auto-triggered or human-initiated).
- **Health check** every 30 minutes (systemd timer).

## Tech stack
<FILL IN: languages, frameworks, infra. Architect maintains this.>

## Definition of Done
A story is "Done" only if ALL of these hold:
1. All acceptance criteria pass automated tests.
2. Code merged to `main` via PR with human approval.
3. CI is green on `main` post-merge.
4. Docs updated (README, changelog, ADR if applicable).
5. Project card moved to Done by orchestrator.
6. No new P0/P1 bugs filed against the story within 24h.

## Communication conventions
- **Issues**: use templates in `.github/ISSUE_TEMPLATE/`.
- **PR comments**: structured (see developer.md and tester.md).
- **Cross-agent**: never DM-style. Always via GitHub Issue or PR comment.
- **Escalation to human**: Discord webhook + GitHub `@`-mention to @atilcan65.

## Things agents must NEVER do
- Push directly to `main`.
- Merge their own PRs.
- Modify `.github/workflows/`, secrets, branch protection without explicit human approval.
- Roll their own auth/crypto.
- Disable failing tests to make CI green.
- Edit other agents' soul files.

## File ownership matrix
| Path | Owner |
|---|---|
| `docs/product/` | @product-manager |
| `docs/backlog/` | @product-manager |
| `docs/designs/` | @architect |
| `docs/decisions/` (ADRs) | @architect |
| `docs/tech-debt.md` | @architect |
| `docs/sprints/` | @orchestrator |
| `docs/bugs/` | @tester |
| `src/`, `tests/` | @developer (writes), @tester (test files), @architect (reviews) |
| `.claude/` | human only |
| `.github/workflows/` | human only (agents propose via PR) |
