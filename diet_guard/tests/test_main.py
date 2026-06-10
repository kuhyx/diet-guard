"""Tests for the package entry points (__init__, __main__).

Importing ``__main__`` executes its module-level code (the ``if __name__`` guard
is excluded from coverage), wiring the ``python -m`` entry point under test.
"""

from __future__ import annotations

import importlib


def test_main_module_imports() -> None:
    """The ``python -m python_pkg.diet_guard`` entry module imports cleanly."""
    module = importlib.import_module("python_pkg.diet_guard.__main__")
    assert hasattr(module, "main")


def test_package_imports() -> None:
    """The package itself imports without side effects."""
    package = importlib.import_module("python_pkg.diet_guard")
    assert package is not None
