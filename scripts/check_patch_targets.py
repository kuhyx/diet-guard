#!/usr/bin/env python3
"""Fail if a test patches a dotted path that no longer resolves.

``unittest.mock.patch("diet_guard._state.FOOD_LOG_FILE", ...)`` fails *open*.
Once a refactor moves ``FOOD_LOG_FILE`` to another module, the old path still
imports, the patch redirects nothing, and the test keeps passing -- while the
suite writes to the real ``~/.local/share/diet_guard``, which
``diet-guard-sync.timer`` then publishes to every other device.

That is why this gate exists rather than a note in CLAUDE.md: the failure it
guards against is silent and green, so only a static check catches it.

Usage (from the repo root):
    python3 scripts/check_patch_targets.py PACKAGE [--tests-root DIR]

``PACKAGE`` is required: only patch targets starting with it are checked, and
a silent default would be the same fail-open shape this script guards
against. ``--tests-root`` defaults to ``PACKAGE/tests``. Only flat packages
at the repo root are supported. Adopting it in another repo:
docs/DOCS-patch-targets.md. A shared ``~/src/utils/patch_targets/`` package is
a separate follow-up, once a second repo actually adopts this script.
"""

from __future__ import annotations

import argparse
import ast
import importlib
import pathlib
import sys
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterator

# Running this as `python3 scripts/check_patch_targets.py` puts *scripts/* on
# sys.path, not the repo root -- so `import diet_guard` fails unless the
# package happens to be installed. It is not, on a CI runner that only
# installs requirements.txt. Without this the resolver's `except ImportError`
# swallowed every lookup and the hook reported all 19 targets as stale, which
# is the exact fail-open shape this script exists to prevent.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))


def _in_package(dotted: str, package: str) -> bool:
    """Whether ``dotted`` is ``package`` or inside it (``pkg`` is not ``pkg_a``)."""
    return dotted == package or dotted.startswith(f"{package}.")


def patch_targets(
    root: pathlib.Path, package: str
) -> Iterator[tuple[pathlib.Path, int, str]]:
    """Yield ``(file, lineno, dotted_target)`` for each literal target in ``package``.

    Only paths into ``package`` are checked; a patch of ``requests`` or ``tk``
    is not ours to validate.
    """
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
                and _in_package(first.value, package)
            ):
                yield path, node.lineno, first.value


def _third_party_missing(exc: ImportError, package: str) -> bool:
    """Whether ``exc`` is a missing dependency, not a missing ``package`` module."""
    missing = getattr(exc, "name", None) or ""
    return isinstance(exc, ModuleNotFoundError) and not _in_package(missing, package)


def _lazy_names(value: ast.expr | None) -> list[str]:
    """The names a PEP 562 ``_LAZY_ATTRS`` table (dict keys or a tuple) serves."""
    if isinstance(value, ast.Dict):
        items: list[ast.expr | None] = list(value.keys)
    elif isinstance(value, (ast.Tuple, ast.List, ast.Set)):
        items = list(value.elts)
    else:
        return []
    return [
        i.value
        for i in items
        if isinstance(i, ast.Constant) and isinstance(i.value, str)
    ]


def defined_statically(parts: list[str], split: int) -> bool:
    """Whether ``parts[split]`` is a top-level name of module ``parts[:split]``.

    Reads the source, never imports it. Only one attribute deep: anything
    deeper cannot be proven statically, so it counts as unresolved.
    """
    source = pathlib.Path(*parts[:split]).with_suffix(".py")
    if len(parts) != split + 1 or not source.is_file():
        return False
    tree = ast.parse(source.read_text(encoding="utf-8"), str(source))
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names = [node.name]
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            names = [t.id for t in targets if isinstance(t, ast.Name)]
            if "_LAZY_ATTRS" in names:
                names += _lazy_names(node.value)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            names = [(a.asname or a.name).split(".")[0] for a in node.names]
        else:
            continue
        if parts[split] in names:
            return True
    return False


def resolves(dotted: str, package: str) -> bool:
    """Whether ``dotted`` names a real attribute reachable from a real module.

    Tries the longest importable module prefix first, then walks the remaining
    segments as attributes -- the same resolution order ``mock.patch`` uses.
    """
    parts = dotted.split(".")
    for split in range(len(parts), 0, -1):
        try:
            module = importlib.import_module(".".join(parts[:split]))
        except ImportError as exc:
            # A module whose own *third-party* import is missing (the relay
            # worker's `rtdb_relay`, absent from the system python this hook
            # runs under) still has a source file: check the name statically
            # rather than call a present target stale.
            if _third_party_missing(exc, package) and defined_statically(parts, split):
                return True
            continue
        obj: object = module
        for attr in parts[split:]:
            if not hasattr(obj, attr):
                return False
            obj = getattr(obj, attr)
        return True
    return False


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    """``package`` (required, no default) and ``--tests-root``."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("package", help="top-level package whose targets to check")
    parser.add_argument(
        "--tests-root",
        type=pathlib.Path,
        help="directory of tests to scan (default: PACKAGE/tests)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """Report every unresolvable patch target; return 1 if any were found."""
    args = _parse_args(argv)
    package: str = args.package
    tests_root: pathlib.Path = args.tests_root or pathlib.Path(package) / "tests"
    if not tests_root.is_dir():
        sys.stderr.write(f"Error: {tests_root} not found; run from the repo root.\n")
        return 1

    # Distinguish "this target moved" from "the package will not import at
    # all". Without this the second case masquerades as the first: every
    # target reports stale at once, which reads like a catastrophic refactor
    # and hides the real error (a missing dependency, a syntax error).
    try:
        importlib.import_module(package)
    except ImportError as exc:
        sys.stderr.write(
            f"Error: cannot import {package} ({exc}); every patch target would "
            f"be reported stale. Fix the import first -- this is an environment "
            f"problem, not a stale patch target.\n",
        )
        return 1

    stale = [
        (path, lineno, target)
        for path, lineno, target in patch_targets(tests_root, package)
        if not resolves(target, package)
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
