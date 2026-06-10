"""Module entry point: ``python -m python_pkg.diet_guard``."""

from __future__ import annotations

import sys

from python_pkg.diet_guard._cli import main

if __name__ == "__main__":
    sys.exit(main())
