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

from gatelock import log_integrity
from gatelock.log_integrity import compute_entry_hmac

from diet_guard import _budget, _budget_history, _state
from diet_guard._constants import (
    BUDGET_FILE as REAL_BUDGET_FILE,
)
from diet_guard._constants import (
    BUDGET_HISTORY_FILE as REAL_BUDGET_HISTORY_FILE,
)
from diet_guard._constants import (
    FOOD_LOG_FILE as REAL_FOOD_LOG_FILE,
)

_PACKAGE_DIR = pathlib.Path(__file__).resolve().parent.parent

#: The real machine-wide key the fixture must redirect away from.
_REAL_HMAC_KEY = pathlib.Path("/etc/workout-locker/hmac.key")

#: Each on-disk state path conftest redirects, mapped to the single package
#: module allowed to name it. Anything else naming one means the redirect no
#: longer covers every reader.
_REDIRECTED_CONSTANTS = {
    "FOOD_LOG_FILE": "_state",
    "BUDGET_FILE": "_budget",
    "BUDGET_HISTORY_FILE": "_budget_history",
    "FOOD_BANK_FILE": "_foodbank",
    "MANUAL_BANK_FILE": "_foodbank_manual",
}


def _names(path: pathlib.Path, constant: str) -> bool:
    """Whether ``path`` mentions ``constant`` at all."""
    tree = ast.parse(path.read_text(encoding="utf-8"), str(path))
    return any(
        (isinstance(node, ast.Name) and node.id == constant)
        or (isinstance(node, ast.Attribute) and node.attr == constant)
        for node in ast.walk(tree)
    )


def test_only_owners_name_redirected_paths() -> None:
    """Each redirected state path is referenced from exactly one module.

    Fails closed: a split that moves a reader of one of these constants into a
    sibling shows up here as a named module, instead of as a test run quietly
    writing to the real ``~/.local/share/diet_guard``.
    """
    for constant, owner in _REDIRECTED_CONSTANTS.items():
        namers = sorted(
            path.stem for path in _PACKAGE_DIR.glob("*.py") if _names(path, constant)
        )
        assert set(namers) <= {owner, "_constants"}, (
            f"{constant} must be named only by _constants (its definition) "
            f"and {owner} (the sole reader conftest patches); found: {namers}"
        )


def test_redirect_moves_writes_off_the_live_paths() -> None:
    """Under the conftest redirect, real writes miss the live paths.

    The complement of the static check: proves each patched constant is the
    one the write path actually resolves, not merely that the name sits in the
    right file.
    """
    live = {
        "_state.FOOD_LOG_FILE": (_state.FOOD_LOG_FILE, REAL_FOOD_LOG_FILE),
        "_budget.BUDGET_FILE": (_budget.BUDGET_FILE, REAL_BUDGET_FILE),
        "_budget_history.BUDGET_HISTORY_FILE": (
            _budget_history.BUDGET_HISTORY_FILE,
            REAL_BUDGET_HISTORY_FILE,
        ),
    }
    for name, (patched, real) in live.items():
        assert patched != real, (
            f"conftest._isolate_state is not redirecting {name} -- "
            "tests would write to real user data"
        )

    _state._write_log({"2026-06-22": []})
    assert _state.FOOD_LOG_FILE.exists(), "write did not land on the redirect"

    _budget.write_budget(2000)
    assert _budget.BUDGET_FILE.exists(), "budget write did not land on the redirect"
    assert _budget_history.BUDGET_HISTORY_FILE.exists(), (
        "budget-history write did not land on the redirect"
    )


def test_hmac_key_is_redirected_off_the_machine_key() -> None:
    """The shared HMAC key points at a temp file, not ``/etc``.

    ``_gate_fixtures._hmac_key`` is autouse, but a fixture only registers if
    ``conftest.py`` *imports* it -- and ruff deletes an import that nothing
    references, which is why every such fixture is also named in conftest's
    ``__all__``. When ``_hmac_key`` was left out of both, this machine's real
    ``/etc/workout-locker/hmac.key`` silently stood in for it: the suite passed
    here and six signing tests failed on CI, which has no such file.

    Asserting the redirect directly makes that a local failure instead of a
    push-time one.
    """
    assert log_integrity.DEFAULT_HMAC_KEY_FILE != _REAL_HMAC_KEY, (
        "_hmac_key is not registered -- add it to conftest's import list AND "
        "its __all__, or tests will pass here and fail on a keyless runner"
    )
    assert compute_entry_hmac({"probe": True}) is not None, (
        "the redirected key does not sign; signing tests will fail closed"
    )
