# Personas — atilprojects

> Stub. PM-owned. Personas are grounded in jobs-to-be-done, not demographics.

Sprint 1 has **one primary** persona. The other two are *adjacent* — they
exist so the team can sanity-check that v1 is not painting itself into a
corner, not because Sprint 1 must serve all three equally.

> ⚠️ **Persona pivot (2026-06-10):** Sprint 1 grooming initially listed
> Devon (backend developer) as primary. The human owner (@atilcan65) clarified
> that the *real* primary is **"Atil-in-2-weeks"** — himself, two weeks
> before a demo, needing a service he can stand up and defend. Devon is
> demoted to adjacent. This file reflects the post-pivot state. A
> `[Scope-Change]` issue tracks the pivot for the team.

---

## 1. Atil-in-2-weeks — Founder / Demo Owner (PRIMARY, Sprint 1)

**Job to be done:** "Two weeks before a demo, I want a FastAPI service I
can stand up from a private template, run with one command, and trust
not to break in front of an audience — so I spend the last 14 days on
the demo's *content*, not on the boilerplate."

**Today (pain):** Two weeks out, the founder realises the service needs
auth, the tests are flaky, the CI is green-on-paper, and `curl
/hello/world` returns a 500. The first 10 seconds of the live demo now
become a debugging session.

**What "great" looks like for Atil in v1:**
- `cp -r template new-service` → `make run` → `curl localhost:8000/healthz`
  returns 200 in **under 5 minutes** with zero tribal knowledge.
- `make test` runs the suite, exits 0, and the same suite runs on CI on
  every push.
- `curl localhost:8000/hello/Atil` returns a friendly JSON — *the*
  signature demo move.
- The merge button reflects a real signal, not a hopeful claim from the
  author of a midnight commit.

**Story → persona mapping (Sprint 1):**
- STORY-001 (FastAPI + /healthz) → Atil can run locally before the demo.
- STORY-002 (one-command tests) → Atil can self-verify before pushing.
- STORY-003 (CI workflow) → Atil gets a signal on every PR, no surprises.
- STORY-004 (GET /hello/{name}) → the **visible** demo artefact (no longer
  STRETCH — promoted to in-scope P1 on 2026-06-10).

---

## 2. Devon — Backend Developer (ADJACENT, demoted from primary 2026-06-10)

**Job to be done:** "When I'm asked to start a new HTTP service, I want
a working, testable, CI-backed skeleton in one command, so I can spend
day 1 on the actual product, not the boilerplate."

**Why demoted:** Devon is the persona most template-tooling writes *for*.
In our case, the template is private and serves the owner first; Devon
is a future user of the same shape, not the buyer of v1. Keep Devon in
the docs so we don't accidentally design something that *only* the owner
can use — but Devon is not the person whose pain we are solving in
Sprint 1.

---

## 3. Maya — DevOps / SRE (ADJACENT, future sprint)

**Job to be done:** "When a PR is opened, I want a trusted, fast, deterministic
test signal, so I don't have to gate-keep the queue manually."

**Why listed now:** If Sprint 1's CI is slow, flaky, or unauditable, Maya
will spend Sprint 3 re-doing it. We don't serve her today, but we don't
*block* her either — that's the bar. The CI story (STORY-003) is the
single thing Sprint 1 ships that exists for *Maya's future self* more
than for Atil's demo.

---

## Anti-patterns the PM will reject

- ❌ "As a **user**, I want ..." — *which* user? Map to a persona.
- ❌ Inventing a 4th persona mid-sprint to justify a pet feature. Add to
  the open-questions list, do not silently expand scope.
- ❌ **Silently pivoting the primary persona mid-sprint without a
  [Scope-Change] issue.** Done once (this pivot), never again without a
  written rationale the next agent can audit.
- ❌ Re-elevating Devon to primary "because the stories fit Devon." The
  fit is a side effect; the buyer is Atil.

## Open questions

- [ ] Is Maya a real second persona, or a hygiene check we can drop in
      v2? → owner: @atilcan65
