"""Guard: the food log's test redirect must actually reach every reader.

``conftest._isolate_state`` redirects the log by patching
``diet_guard._state.FOOD_LOG_FILE``. That patch reaches only code which
resolves the constant *through that module's globals*. Split a function that
opens the log into a sibling -- as the 250-line sweep did to ``_state.py`` --
and the sibling reads its own copy of the name, the patch redirects nothing,
and the suite writes to the real ``~/.local/share/diet_guard``, which the next
sync tick publishes to every other device.

That failure is silent and green: ``check_patch_targets.py`` still exits 0
(the dotted path resolves), and the ~5s runtime is unchanged (this is a file
write, not a network call). Hence a direct assertion, in two parts: only
``_state`` may name the constant, and the redirect demonstrably moves a real
write off the live path.
"""

from __future__ import annotations

import ast
import pathlib

from diet_guard import _state
from diet_guard._constants import FOOD_LOG_FILE as REAL_FOOD_LOG_FILE

_PACKAGE_DIR = pathlib.Path(__file__).resolve().parent.parent

#: The one module allowed to open the food log. Everything else must go
#: through its ``_read_raw_log`` / ``_write_log``.
_LOG_FILE_OWNER = "_state"


def _names_food_log_file(path: pathlib.Path) -> bool:
    """Whether ``path`` mentions ``FOOD_LOG_FILE`` at all."""
    tree = ast.parse(path.read_text(encoding="utf-8"), str(path))
    return any(
        (isinstance(node, ast.Name) and node.id == "FOOD_LOG_FILE")
        or (isinstance(node, ast.Attribute) and node.attr == "FOOD_LOG_FILE")
        for node in ast.walk(tree)
    )


def test_only_state_names_the_log_file() -> None:
    """``FOOD_LOG_FILE`` is referenced from exactly one package module.

    Fails closed: a split that moves a log reader into a sibling shows up here
    as a named module, instead of as a test run quietly writing to the real
    food log.
    """
    namers = sorted(
        path.stem for path in _PACKAGE_DIR.glob("*.py") if _names_food_log_file(path)
    )
    assert set(namers) <= {_LOG_FILE_OWNER, "_constants"}, (
        "FOOD_LOG_FILE must be named only by _constants (its definition) and "
        f"_state (the sole reader conftest patches); found: {namers}"
    )


def test_redirect_moves_writes_off_the_live_log() -> None:
    """Under the conftest redirect, a real write misses the live path.

    The complement of the static check: proves the patched constant is the one
    the write path actually resolves, not merely that the name is in the right
    file.
    """
    assert _state.FOOD_LOG_FILE != REAL_FOOD_LOG_FILE, (
        "conftest._isolate_state is not redirecting diet_guard._state."
        "FOOD_LOG_FILE -- tests would write to the real food log"
    )

    _state._write_log({"2026-06-22": []})
    assert _state.FOOD_LOG_FILE.exists(), "write did not land on the redirect"
