# STORY-004: GET /hello/{name} greeting endpoint

## User Story
As a **founder two weeks out from a demo (Atil-in-2-weeks)**,
I want **a `GET /hello/{name}` endpoint that returns a JSON greeting**,
So that **the first 10 seconds of a live demo are a clean, branded moment — not a 404 — and I have a non-trivial routing fixture to show.**

## Why now
This is the *visible* endpoint — the one the demo audience sees, and the
one the founder curls in front of them to prove the service is real.
With Atil-in-2-weeks as primary persona, the greeting endpoint is no
longer cosmetic; it is **the signature demo move**. Promoted from
optional to in-scope P1 on 2026-06-10 (see
`docs/sprints/current/scope-change-001-persona-pivot.md` once published,
or the `[Scope-Change]` GitHub issue for now).

The `name` path parameter also gives us a non-trivial fixture to test
URL routing, escaping, and validation — small surface, real value.
Tagged for @developer because it is a one-route feature with no design
questions, in the small scope of "FastAPI starter" patterns.

> Status history: this story was originally proposed as optional
> during the initial grooming pass. The human owner (@atilcan65)
> promoted it to commitment on 2026-06-10: "sprint'e dahil et" — kept
> in Sprint 1, not deferred to Sprint 2. AC are unchanged.

## Acceptance Criteria

- **AC1** — GIVEN the service is running (STORY-001 satisfied)
  WHEN the developer `curl`s `GET /hello/world`
  THEN the response is **HTTP 200** with body
  `{"message":"hello, world"}` and `Content-Type: application/json`.
- **AC2** — GIVEN the service is running
  WHEN the developer `curl`s `GET /hello/Atil`
  THEN the response is **HTTP 200** with body
  `{"message":"hello, Atil"}` — *exact case preserved* (no lowercasing).
- **AC3** — GIVEN the service is running
  WHEN the developer `curl`s `GET /hello/` (missing name segment)
  THEN the response is **HTTP 404** (FastAPI default for unmatched path,
  not a 500).
- **AC4** — GIVEN the service is running
  WHEN the developer `curl`s `GET /hello/%20` (URL-encoded space)
  THEN the response is **HTTP 200** with body
  `{"message":"hello,  "}` and the test asserts no 5xx.
- **AC5** — GIVEN the test suite (STORY-002)
  WHEN the developer runs it
  THEN at least **two** new tests exist: one happy-path (AC1) and one
  case-preservation (AC2).

## Out of scope
- Query parameters (`?lang=tr`, `?formal=true`) — keep v1 to the path
  param only; query-param surface is a Sprint 2 conversation.
- POST/PUT/DELETE on `/hello` — read-only, GET only.
- Rate-limiting, abuse prevention — `/hello` is a demo endpoint, not a
  public surface.
- Personalisation, user accounts, name validation beyond URL safety —
  none of this is needed for "demo the service is alive".
- Localisation of the greeting word itself (Turkish "merhaba", etc.) —
  intentionally English for v1 to keep the JSON shape stable.

## Open questions
- [ ] Do we cap name length (e.g. 64 chars) to bound log-spam risk?
      Trade-off: nice safety net vs extra test surface. → owner:
      @developer (recommend: cap at 64 in v1)
- [ ] Do we reject names with control characters, or pass them through
      as-is? → owner: @developer
- [ ] Is the response key `message` (recommended) or `greeting` / `text`?
      Pick once, document in OpenAPI. → owner: @developer

## Mockups / references

```
$ curl -i localhost:8000/hello/world
HTTP/1.1 200 OK
content-type: application/json
{"message":"hello, world"}

$ curl -i localhost:8000/hello/Atil
HTTP/1.1 200 OK
content-type: application/json
{"message":"hello, Atil"}
```

## Dependencies
- Upstream: STORY-001 (service skeleton + routing).
- Downstream: none. This is a leaf.

## Metrics of success
- Leading: the `/hello/{name}` test case count is **≥ 2** in the suite.
- Lagging: zero "demo failed on the first curl" incidents in the 30 days
  after release.
