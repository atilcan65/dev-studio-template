"""FastAPI application — STORY-001 skeleton + STORY-004 greeting.

Implements the contract from docs/designs/STORY-001-design.md and ADR-0001.
Two routes in v1:
- GET /healthz — synchronous liveness probe, 200 with {"status": "ok"}.
- GET /hello/{name} — demo greeting, 200 with {"message": "hello, {name}"}.

Contract pin (do NOT change without a design pass — see ADR-0001):
- Sync handlers (no I/O → no need for `async def`).
- No DB / Redis / HTTP calls in these handlers. A future deep-check liveness
  probe (DB ping, downstream HTTP) is a separate story, not an in-place edit.
"""

import os
import signal

from fastapi import FastAPI, Path

from app import __version__

app = FastAPI(
    title="atilprojects",
    version=__version__,
    description="Sprint 1 hello-world FastAPI service (STORY-001 + STORY-004).",
)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """Liveness probe.

    Contract: synchronous, no I/O, returns 200 with {"status": "ok"}.
    Do not add DB/Redis/HTTP calls here without a separate design pass.
    """
    return {"status": "ok"}


@app.get("/hello/{name}")
def hello(
    name: str = Path(..., min_length=1, max_length=64),
) -> dict[str, str]:
    """Demo greeting endpoint (STORY-004).

    Contract: returns 200 with {"message": "hello, {name}"}.
    - Case is preserved verbatim (no lowercasing).
    - URL-decoded values pass through; `/hello/%20` → `"hello,  "`.
    - Path segment is required; missing name → 404 (FastAPI default).
    - Name is capped at 64 chars to bound log-spam risk.
    """
    return {"message": f"hello, {name}"}


# ─────────────────────────────────────────────────────────────────────────────
# SIGTERM handler (STORY-002 TC-8 unblock).
# Without this, `kill <pid>` (SIGTERM) exits the uvicorn process with
# code 143 (= 128 + SIGTERM), which breaks container/k8s/systemd graceful
# shutdown and is the canonical RED in PR #24's test_sigterm_exits_zero.
# We register os._exit(0) at module-import time, after the app is fully
# constructed, so a `kill` on the uvicorn process exits 0 like SIGINT does.
#
# Why os._exit (C-level _exit(2)) instead of sys.exit (which raises
# SystemExit): the asyncio event loop has a pending Starlette `lifespan`
# task awaiting receive_queue.get(). When SystemExit propagates, that
# pending task is cancelled, and the cancellation cascades into a
# CancelledError traceback on stderr — which violates STORY-001 AC4
# ("prints a clean shutdown line (no traceback)"). os._exit() bypasses
# Python cleanup (no atexit, no finally chains, no SystemExit propagation),
# so the loop's pending tasks get terminated with the process, not
# cancelled. No traceback, exit 0, clean.
#
# Side-effect scope: SIGTERM only; SIGINT keeps uvicorn's own handler
# (which already exits 0 — see PR #24's TC-7 green).
# ─────────────────────────────────────────────────────────────────────────────


def _handle_sigterm(signum: int, frame: object) -> None:
    """SIGTERM handler — exit cleanly with code 0 (mirrors SIGINT/uvicorn).

    Uses os._exit(0) (C-level _exit(2)) so the asyncio loop's pending
    tasks don't log a CancelledError traceback on shutdown. Scope: SIGTERM
    only. SIGINT keeps uvicorn's own handler.
    """
    os._exit(0)  # intentional: bypass Python cleanup (see module-level comment)


signal.signal(signal.SIGTERM, _handle_sigterm)
