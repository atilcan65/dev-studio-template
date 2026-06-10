# Architecture Decision Records — Index

This index lists every ADR the team has produced. ADRs are immutable once
`Accepted`; superseding decisions live in a new ADR that references the old
one in its `Supersedes` field.

| ID | Title | Status | Date | Deciders | Related |
|----|-------|--------|------|----------|---------|
| [ADR-0001](ADR-0001-fastapi-skeleton.md) | FastAPI service skeleton — Python pin, package manager, run command, layout | Accepted | 2026-06-10 | @architect, @atilcan65 | STORY-001, STORY-002, STORY-003, STORY-004 |
| ADR-0002 | _(planned)_ GitHub Actions action pin policy + cache strategy | Proposed (queued) | — | @architect | STORY-003 |

## Conventions

- **Path**: `docs/decisions/ADR-NNNN-<slug>.md`
- **ID**: monotonically increasing, zero-padded to 4 digits
- **Slug**: kebab-case, short, filename-safe
- **Status lifecycle**: Proposed → Accepted → (optionally) Superseded by ADR-MMMM
- **Header**: every ADR starts with `# ADR-NNNN: <title>` followed by a YAML-style frontmatter block (Status, Date, Deciders, Supersedes, Related)

## Pending proposals

- **ADR-0002** — GitHub Actions action pin policy + cache strategy. Required before STORY-003 implementation begins. Architect will draft when STORY-003 enters `Ready`.
