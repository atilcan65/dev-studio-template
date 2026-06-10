"""Skeleton smoke test for the FastAPI service (STORY-001).

This is the MINIMUM test surface for the skeleton: it proves the app
imports, exposes a /healthz route, and that route returns the contract
response. The full contract test suite — 404 routing, determinism,
clean-shutdown subprocess lifecycle, README on-ramp timing — is owned
by @tester and lands in STORY-002.
"""

from fastapi.testclient import TestClient


def test_healthz_returns_ok_json() -> None:
    """AC2 of STORY-001: GET /healthz → 200 with {"status": "ok"} JSON."""
    # Importing inside the test (not at module top) so the failure mode for
    # a missing app/main.py is a clear ModuleNotFoundError, not a confusing
    # collection-time error.
    from app.main import app

    client = TestClient(app)
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.headers["content-type"] == "application/json"
    assert response.json() == {"status": "ok"}
