#!/usr/bin/env python3
"""Fail if a test patches a dotted path that no longer resolves.

``unittest.mock.patch("diet_guard._state.FOOD_LOG_FILE", ...)`` fails *open*.
Once a refactor moves ``FOOD_LOG_FILE`` to another module, the old path still
imports, the patch redirects nothing, and the test keeps passing -- while the
suite writes to the real ``~/.local/share/diet_guard``, which
``diet-guard-sync.timer`` then publishes to every other device.

That is why this gate exists rather than a note in CLAUDE.md: the failure it
guards against is silent and green, so only a static check catches it.

Usage:
    python3 scripts/check_patch_targets.py
"""

from __future__ import annotations

import ast
import importlib
import pathlib
import sys
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterator

#: Only paths into this package are checked; a patch of `requests` or `tk` is
#: not ours to validate.
PACKAGE = "diet_guard"

TESTS_ROOT = pathlib.Path(PACKAGE) / "tests"


def patch_targets(root: pathlib.Path) -> Iterator[tuple[pathlib.Path, int, str]]:
    """Yield ``(file, lineno, dotted_target)`` for every literal patch target."""
    for path in sorted(root.rglob("*.py")):
        tree = ast.parse(path.read_text(), str(path))
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            name = getattr(node.func, "attr", None) or getattr(node.func, "id", None)
            if name != "patch" or not node.args:
                continue
            first = node.args[0]
            if (
                isinstance(first, ast.Constant)
                and isinstance(first.value, str)
                and first.value.startswith(PACKAGE)
            ):
                yield path, node.lineno, first.value


def resolves(dotted: str) -> bool:
    """Whether ``dotted`` names a real attribute reachable from a real module.

    Tries the longest importable module prefix first, then walks the remaining
    segments as attributes -- the same resolution order ``mock.patch`` uses.
    """
    parts = dotted.split(".")
    for split in range(len(parts), 0, -1):
        try:
            module = importlib.import_module(".".join(parts[:split]))
        except ImportError:
            continue
        obj: object = module
        for attr in parts[split:]:
            if not hasattr(obj, attr):
                return False
            obj = getattr(obj, attr)
        return True
    return False


def main() -> int:
    """Report every unresolvable patch target; return 1 if any were found."""
    if not TESTS_ROOT.is_dir():
        sys.stderr.write(f"Error: {TESTS_ROOT} not found; run from the repo root.\n")
        return 1

    stale = [
        (path, lineno, target)
        for path, lineno, target in patch_targets(TESTS_ROOT)
        if not resolves(target)
    ]
    for path, lineno, target in stale:
        sys.stderr.write(f"{path}:{lineno}: patch target does not resolve: {target}\n")

    if stale:
        plural = "" if len(stale) == 1 else "s"
        sys.stderr.write(
            f"\n{len(stale)} stale patch target{plural}. A patch that does not "
            f"resolve silently redirects nothing -- the test passes while writing "
            f"to real user state. Update the path to where the name now lives.\n"
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
