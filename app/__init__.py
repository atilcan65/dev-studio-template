"""atilprojects — FastAPI service package.

Marks `app` as a package and exposes a `__version__` string so any future
diagnostics endpoint or `/version` route can read it without a hard-coded
literal scattered across the codebase.
"""

__version__ = "0.1.0"
