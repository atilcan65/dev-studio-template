# Product Vision — atilprojects

> Stub. PM-owned. Refine as the product gains real users.

## One-paragraph vision

**atilprojects** is a *boring, reliable* **private** FastAPI template that lets
the owner (@atilcan65) stand up a demo-ready HTTP service two weeks before
a deadline. We optimise for the *first commit to first green CI* path:
clone → run → test → push → see green. Everything that does not shorten
that path is out of scope for v1.

> ⚠️ **Launch shape (resolved 2026-06-10):** *private template*, not
> open-source. The public-release question is parked; if we ever go public,
> we re-derive the vision, not retrofit it.

## Why this vision (rationale)

The single biggest time-sink on most new services is **plumbing** — pick a
framework, wire uvicorn, add `/healthz`, write a `conftest.py`, fight with
pytest fixtures, write a CI YAML that won't be flaky. None of this is product
value, but it gates every other piece of work.

By owning the boring path end-to-end, we make every later feature story
shorter. The return on a great v1 is *compounding*: Sprint 2 can land in
hours because Sprint 1's run/test/CI loop already works.

## What we are NOT building (v1 anti-vision)

- ❌ Multi-tenant SaaS, billing, auth flows — those are product features, not
  infrastructure. Each will earn its own sprint.
- ❌ Custom CI runners, on-prem deployment, K8s operators — too speculative
  before a real user has a real complaint.
- ❌ Framework parity (Flask, Django, Litestar) — pick one, execute, then
  re-evaluate after users vote with their feet.

## Success in 6 months looks like

- The owner can `git clone` (or `cp` from the template) → `make run` →
  `curl localhost:8000/healthz` in **under 5 minutes** with zero tribal
  knowledge, two weeks before a deadline.
- The default CI pipeline is *trusted*: nobody re-runs it locally before
  merging.
- At least 3 *internal* services (the owner's, not the world's) cite this
  template as their starting point.

## Open questions for the human owner

- [ ] Do we ever expect **non-Python services** to want the same onboarding
      shape, or is FastAPI-only acceptable long-term? → owner: @atilcan65
