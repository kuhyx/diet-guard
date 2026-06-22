"""Module entry point: ``python -m diet_guard``."""

from __future__ import annotations

import sys

from diet_guard._cli import main

if __name__ == "__main__":
    sys.exit(main())
