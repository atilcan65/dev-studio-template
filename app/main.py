"""FastAPI application — STORY-001 skeleton.

Implements the contract from docs/designs/STORY-001-design.md and ADR-0001.
The service exposes exactly one route in v1: GET /healthz, a synchronous
liveness handler that returns 200 OK with {"status": "ok"}.

Contract pin (do NOT change without a design pass — see ADR-0001):
- Sync handler (no I/O → no need for `async def`).
- Body shape is exactly {"status": "ok"}; content-type application/json
  is set by FastAPI's default JSONResponse.
- No DB / Redis / HTTP calls in this handler. A future deep-check liveness
  probe (DB ping, downstream HTTP) is a separate story, not an
  in-place edit to this handler.
"""

from fastapi import FastAPI

from app import __version__

app = FastAPI(
    title="atilprojects",
    version=__version__,
    description="Sprint 1 hello-world FastAPI service (STORY-001).",
)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """Liveness probe.

    Contract: synchronous, no I/O, returns 200 with {"status": "ok"}.
    Do not add DB/Redis/HTTP calls here without a separate design pass.
    """
    return {"status": "ok"}
