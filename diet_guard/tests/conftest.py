"""Shared fixtures for diet_guard tests.

Three safety nets run for every test:

* ``_isolate_state`` redirects the food log, sealed budget, gate lock, and
  sync token into ``tmp_path`` so a test can never read or clobber the real
  ``~/.local/share`` or ``~/.config/diet_guard``.
* ``_block_real_tk`` swaps ``tk`` and the ``GateRoot`` window class inside
  ``_gatelock`` for mocks, so no test can open a real fullscreen window or grab
  the keyboard even if it forgets to.
* ``_block_real_vt`` makes ``gatelock``'s VT-switch disable a no-op, so a
  prod-mode (``demo_mode=False``) gate built in a test never runs a real
  ``setxkbmap`` against the live X session.

The ``gate`` fixture and its supporting fakes (``FakeEntry``, ``_FAKE_TK``, ...)
build a demo :class:`~diet_guard._gatelock.MealGate` whose widgets
are functional in-memory stand-ins, shared by ``test_gatelock.py`` and
``test_gatelock_mealflow.py``.
"""

from __future__ import annotations

from typing import TYPE_CHECKING
from unittest.mock import patch

import pytest

from diet_guard._estimator import Nutrition

# Importing these fixtures IS their registration: pytest discovers fixtures
# defined *or imported* in a conftest, and ``pytest_plugins`` is an error in a
# non-root conftest. They look unused and are not -- do not "tidy" them away.
from diet_guard.tests._gate_fixtures import (
    _GATE_TK_MODULES,
    FAKE_OUTPUTS,
    TWO_OUTPUTS,
    _block_real_tk,
    _block_real_vt,
    _hermetic_gatelock,
    dual_output,
    fake_tk,
    gate,
)
from diet_guard.tests._tk_fakes import (
    _FAKE_TK,
    _FAKE_TTK,
    FakeCanvas,
    FakeEntry,
    FakeListbox,
    FakeNotebook,
    FakeRadiobutton,
    FakeScrollbar,
    FakeStyle,
    FakeText,
    FakeVar,
    FakeWidget,
    _FakeTclError,
)

# Re-exported: the fake widgets moved into the package so this file stays
# under the 250-line cap, but tests import them from conftest by name.
__all__ = [
    "FAKE_OUTPUTS",
    "TWO_OUTPUTS",
    "_FAKE_TK",
    "_FAKE_TTK",
    # The autouse fixtures: importing them here is what registers them with
    # pytest, and naming them here is what stops a linter deleting the import.
    "_GATE_TK_MODULES",
    "FakeCanvas",
    "FakeEntry",
    "FakeListbox",
    "FakeNotebook",
    "FakeRadiobutton",
    "FakeScrollbar",
    "FakeStyle",
    "FakeText",
    "FakeVar",
    "FakeWidget",
    "_FakeTclError",
    "_block_real_tk",
    "_block_real_vt",
    "_hermetic_gatelock",
    "dual_output",
    "dual_output",
    "fake_tk",
    "fake_tk",
    "gate",
    "gate",
]

if TYPE_CHECKING:
    from collections.abc import Iterator
    from pathlib import Path


@pytest.fixture(autouse=True)
def _isolate_state(tmp_path: Path) -> Iterator[None]:
    """Redirect all on-disk diet_guard state into a temp dir."""
    with (
        patch(
            "diet_guard._budget.BUDGET_FILE",
            tmp_path / ".budget",
        ),
        patch(
            "diet_guard._budget_history.BUDGET_HISTORY_FILE",
            tmp_path / ".budget_history",
        ),
        patch(
            "diet_guard._state.FOOD_LOG_FILE",
            tmp_path / "food_log.json",
        ),
        patch(
            "diet_guard._foodbank.FOOD_BANK_FILE",
            tmp_path / "food_bank.json",
        ),
        patch(
            "diet_guard._foodbank_manual.MANUAL_BANK_FILE",
            tmp_path / "food_bank_manual.json",
        ),
        patch(
            "diet_guard._gatelock.GATE_LOCK_FILE",
            tmp_path / ".gate.lock",
        ),
        patch(
            "diet_guard._sync_client.SYNC_TOKEN_FILE",
            tmp_path / "sync_token",
        ),
        patch(
            "diet_guard._sync.SYNC_STATE_FILE",
            tmp_path / "sync_state.json",
        ),
        # Without this a test that syncs mints a uuid into the REAL
        # ~/.local/share/diet_guard/.device_id, and this machine's live sync
        # identity is decided by whichever test happened to run first.
        patch(
            "diet_guard._device.SYNC_DEVICE_ID_FILE",
            tmp_path / ".device_id",
        ),
        # `run_sync` reads this to decide whether to build a Firebase-primary
        # mirror. On a developer machine the real file exists, so without this
        # every sync test would sign in and push to the live database.
        patch(
            "diet_guard._sync_client.CONFIG_FILE",
            tmp_path / "nonexistent-firebase.json",
        ),
    ):
        yield


def _nutrition(kcal: float = 100, grams: float = 100) -> Nutrition:
    """A simple reference nutrition for driving the gate form."""
    return Nutrition(kcal, 10, 20, 5, grams, "food bank")
