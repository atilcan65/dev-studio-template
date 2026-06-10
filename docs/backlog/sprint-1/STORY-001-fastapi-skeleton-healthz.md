# STORY-001: One-command runnable FastAPI service with /healthz

## User Story
As a **founder two weeks out from a demo (Atil-in-2-weeks)**,
I want **a FastAPI service I can stand up from a private template, run with a single command, and a `/healthz` endpoint that returns 200 OK**,
So that **the morning of the demo I am reading my talk track, not debugging a 500 in front of an audience.**

## Why now
Sprint 1's whole purpose is to close the "first commit to first green CI"
loop. If we cannot run the service locally on day 1, every later story is
gated on boilerplate — and the *demo clock* starts ticking the moment we
say "yes" to a date. This is the *spine* — no other story is independently
shippable without it. Tagged `needs-design` because the package layout,
run strategy (`uvicorn` vs `python -m`), and Python version pin are
choices the @architect should make once, not re-litigated per story.

> Persona note (2026-06-10): this story was originally framed around
> "Devon the backend developer" (see `docs/product/personas.md` §Anti-patterns).
> The primary persona is now Atil-in-2-weeks. AC are unchanged because the
> *behaviour* is the same; the *who* shifted.

## Acceptance Criteria

- **AC1** — GIVEN a clean clone of the repo
  WHEN the developer runs the documented single command (e.g. `make run` or
  `uv run uvicorn ...`)
  THEN the FastAPI process binds to `localhost:8000` within 5 seconds and
  prints a "Uvicorn running on..." log line.
- **AC2** — GIVEN the service is running locally
  WHEN the developer `curl`s `GET /healthz`
  THEN the response is **HTTP 200** with body `{"status":"ok"}` and
  `Content-Type: application/json`.
- **AC3** — GIVEN the service is running
  WHEN the developer `curl`s any unknown path (e.g. `/nope`)
  THEN the response is **HTTP 404** (not 500, not a stack trace).
- **AC4** — GIVEN the service process is killed (Ctrl-C, `kill`, or process
  exit)
  WHEN the developer inspects the terminal
  THEN the process exits with status code 0 and prints a clean shutdown
  line (no traceback).
- **AC5** — GIVEN a developer on a clean machine
  WHEN they follow the README "Getting started" section
  THEN they reach `curl /healthz → 200` in **≤ 5 minutes** with no
  out-of-band tribal knowledge.

## Out of scope
- Authentication, rate limiting, CORS, HTTPS termination — none of this is
  needed for "service is alive".
- Persistent storage, database, Redis, queues — `/healthz` is a liveness
  signal, not a readiness probe with deps.
- Containerization (Dockerfile, compose) — Sprint 1 ships the local loop
  first; containerization is a separate story when needed.
- `GET /hello/{name}` — see STORY-004.

## Open questions
- [ ] Python version pin: 3.11, 3.12, or 3.13? → owner: @architect
- [ ] Package manager: `uv`, `poetry`, or `pip + venv`? Trade-off is dev
  ergonomics vs onboarding surface. → owner: @architect
- [ ] Run command convention: `make run`, `task run`, or just `uv run ...`?
  → owner: @architect
- [ ] Does /healthz need to be async-only, or is sync acceptable for v1?
  → owner: @architect

## Mockups / references
- ASCII:

  ```
  $ make run
  Uvicorn running on http://127.0.0.1:8000 (Press CTRL+C to quit)

  $ curl -i localhost:8000/healthz
  HTTP/1.1 200 OK
  content-type: application/json
  {"status":"ok"}
  ```

## Dependencies
- Upstream: none. This is the trunk.
- Downstream: STORY-002 (tests need a service to test), STORY-003 (CI needs
  a service to build), STORY-004 (extends the route table).

## Metrics of success
- Leading: time from `cp -r template new-service` (or `git clone`) to first
  `200 OK` on `/healthz` ≤ 5 min on a clean laptop.
- Lagging: zero demo-day incidents traceable to "service didn't start" or
  "`/healthz` returned 5xx" in the 30 days after release.
