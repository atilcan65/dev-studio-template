"""In-process sanity check for the SIGTERM handler (STORY-002 TC-8).

The full subprocess lifecycle (spawn uvicorn, send SIGTERM, assert exit 0)
is owned by the tester in tests/test_lifecycle.py. This file is a fast
in-process pin: it proves that importing app.main registers a non-default
SIGTERM handler that calls os._exit(0).

Why a separate file (not test_lifecycle.py): different scope (in-process
vs subprocess), different agent (developer vs tester), avoids merge
conflict when both PRs land.

Why os._exit (not sys.exit): see app/main.py — os._exit(0) bypasses Python
cleanup so the asyncio loop's pending Starlette `lifespan` task is
terminated with the process instead of being cancelled and producing a
CancelledError traceback (which would violate STORY-001 AC4).
"""

import signal
from unittest.mock import patch


def test_sigterm_handler_is_registered_on_import() -> None:
    """Importing app.main must install a non-default SIGTERM handler.

    This is the in-process pin for PR #24's TC-8. If app.main regresses
    to the default (SIG_DFL), this test fails before any subprocess is
    even spawned.
    """
    # Force a fresh import so the side effect is observable even if
    # another test already imported app.main in the same process.
    import importlib

    import app.main

    importlib.reload(app.main)

    handler = signal.getsignal(signal.SIGTERM)
    assert handler is not signal.SIG_DFL, (
        "SIGTERM handler still at SIG_DFL — app/main.py regression"
    )
    assert handler is not signal.SIG_IGN, "SIGTERM handler is SIG_IGN (would swallow kill)"
    assert callable(handler), f"SIGTERM handler is not callable: {handler!r}"


def test_sigterm_handler_calls_os_exit_zero() -> None:
    """The registered handler must call os._exit(0), mirroring SIGINT/uvicorn.

    We mock os._exit (not sys.exit) because the handler uses the C-level
    _exit(2) syscall to bypass Python cleanup. See app/main.py for the
    full rationale (asyncio CancelledError traceback avoidance).
    """
    import importlib

    import app.main

    importlib.reload(app.main)

    handler = signal.getsignal(signal.SIGTERM)
    assert callable(handler)

    with patch("os._exit") as mock_exit:
        handler(signal.SIGTERM, None)  # signal.signal handlers get (signum, frame)

    mock_exit.assert_called_once_with(0)
