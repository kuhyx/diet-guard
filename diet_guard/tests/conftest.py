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

from contextlib import ExitStack
from typing import TYPE_CHECKING

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
    _hmac_key,
    dual_output,
    fake_tk,
    gate,
)
from diet_guard.tests._state_redirects import state_redirects
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
    "_hmac_key",
    "dual_output",
    "fake_tk",
    "gate",
]

if TYPE_CHECKING:
    from collections.abc import Iterator
    from pathlib import Path


@pytest.fixture(autouse=True)
def _isolate_state(tmp_path: Path) -> Iterator[None]:
    """Redirect all on-disk diet_guard state into a temp dir.

    Built as a list fed through an ``ExitStack`` rather than one ``with``
    tuple: the tuple form is a statically nested block per entry, and at
    ~20 redirects CPython refuses to compile it.
    """
    redirects = state_redirects(tmp_path)
    with ExitStack() as stack:
        for redirect in redirects:
            stack.enter_context(redirect)
        yield


def _nutrition(kcal: float = 100, grams: float = 100) -> Nutrition:
    """A simple reference nutrition for driving the gate form."""
    return Nutrition(kcal, 10, 20, 5, grams, "food bank")
