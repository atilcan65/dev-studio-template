# Makefile — atilprojects Sprint 1
# Implements the canonical run/test commands pinned in ADR-0001.
# Every command in this file is a thin wrapper around `uv run` so the
# developer never needs to manage a virtualenv by hand.

.PHONY: help install run test lint format clean

# `make` or `make help` → list the available targets.
help:
	@echo "atilprojects — Sprint 1 make targets"
	@echo ""
	@echo "  make install   first-time setup (uv sync, install dev extras)"
	@echo "  make run       boot uvicorn on 127.0.0.1:8000 (foreground)"
	@echo "  make test      run the pytest suite"
	@echo "  make lint      ruff check"
	@echo "  make format    ruff format (in-place)"
	@echo "  make clean     remove caches, build artefacts, the .venv"

# Install all runtime + dev dependencies into the project venv.
# ADR-0001 §Decision: "uv sync (or `uv pip install -e ".[dev]"`) as the install step"
install:
	uv sync --extra dev

# Run the service. ADR-0001 pins the exact string below; the README and any
# future CI workflow MUST use the same import path + bind address.
run:
	uv run uvicorn app.main:app --host 127.0.0.1 --port 8000

# Run the test suite. STORY-002 owns the contract tests; for STORY-001 this
# is the skeleton smoke test (proves the app object + /healthz route work).
test:
	uv run pytest

# Lint with ruff. Runs the same rule set configured in pyproject.toml.
lint:
	uv run ruff check app tests

# Auto-format with ruff.
format:
	uv run ruff format app tests
	uv run ruff check --fix app tests

# Remove local caches. CI never depends on these; safe to nuke on a dev box.
clean:
	rm -rf .pytest_cache .ruff_cache .venv __pycache__
	find . -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name '*.egg-info' -exec rm -rf {} + 2>/dev/null || true
