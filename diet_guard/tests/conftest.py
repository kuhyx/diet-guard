"""Shared fixtures for diet_guard tests.

Two safety nets run for every test:

* ``_isolate_state`` redirects the food log, sealed budget, and gate lock into
  ``tmp_path`` so a test can never read or clobber the real ``~/.local/share``.
* ``_block_real_tk`` swaps ``tk`` and the ``_GateRoot`` window class inside
  ``_gatelock`` for mocks, so no test can open a real fullscreen window or grab
  the keyboard even if it forgets to.

The ``gate`` fixture and its supporting fakes (``FakeEntry``, ``_FAKE_TK``, ...)
build a demo :class:`~python_pkg.diet_guard._gatelock.MealGate` whose widgets
are functional in-memory stand-ins, shared by ``test_gatelock.py`` and
``test_gatelock_mealflow.py``.
"""

from __future__ import annotations

from contextlib import ExitStack
from types import SimpleNamespace
from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

import pytest

from python_pkg.diet_guard import (
    _gatelock,
    _gatelock_core,
    _gatelock_mealflow,
    _gatelock_nutrition,
    _gatelock_ui,
    _gatelock_window,
)
from python_pkg.diet_guard._estimator import Nutrition
from python_pkg.diet_guard._gatelock import MealGate

if TYPE_CHECKING:
    from collections.abc import Iterator
    from pathlib import Path


@pytest.fixture(autouse=True)
def _isolate_state(tmp_path: Path) -> Iterator[None]:
    """Redirect all on-disk diet_guard state into a temp dir."""
    with (
        patch(
            "python_pkg.diet_guard._budget.BUDGET_FILE",
            tmp_path / ".budget",
        ),
        patch(
            "python_pkg.diet_guard._state.FOOD_LOG_FILE",
            tmp_path / "food_log.json",
        ),
        patch(
            "python_pkg.diet_guard._foodbank.FOOD_BANK_FILE",
            tmp_path / "food_bank.json",
        ),
        patch(
            "python_pkg.diet_guard._gatelock.GATE_LOCK_FILE",
            tmp_path / ".gate.lock",
        ),
    ):
        yield


@pytest.fixture(autouse=True)
def _block_real_tk() -> Iterator[None]:
    """Replace tk + the window class in _gatelock so no real window can open."""
    with (
        patch("python_pkg.diet_guard._gatelock.tk", MagicMock()),
        patch("python_pkg.diet_guard._gatelock._GateRoot", MagicMock()),
    ):
        yield


@pytest.fixture(autouse=True)
def _hmac_key(tmp_path: Path) -> Iterator[None]:
    """Point the shared HMAC key at a deterministic temp file.

    Makes signing/verification work the same in any environment (including CI,
    which has no ``/etc/workout-locker/hmac.key``).  Tests that need the
    no-key path patch ``compute_entry_hmac`` to return None locally.
    """
    key = tmp_path / "hmac.key"
    key.write_bytes(b"diet-guard-test-key-0123456789ab")
    with patch("python_pkg.shared.log_integrity.HMAC_KEY_FILE", key):
        yield


# --------------------------------------------------------------------------
# Gate fixture and its functional tk fakes
# --------------------------------------------------------------------------
#
# A functional fake ``tk`` (stateful Entry/Text/Listbox/StringVar widgets and a
# real, catchable ``TclError``) replaces the blanket MagicMock above for the
# duration of each gate test, so the window's *logic* runs for real against
# in-memory widgets without ever opening a window or grabbing the keyboard.


class _FakeTclError(Exception):
    """Stand-in for ``tkinter.TclError`` (a real, catchable exception)."""


class FakeVar:
    """A functional ``StringVar``: stores and returns a string."""

    def __init__(self, master: object = None, value: str = "") -> None:
        self._value = value

    def get(self) -> str:
        return self._value

    def set(self, value: str) -> None:
        self._value = value


class FakeEntry:
    """A functional one-line entry (delete clears, insert appends)."""

    def __init__(self, *args: object, **kwargs: object) -> None:
        self._value = ""

    def get(self) -> str:
        return self._value

    def delete(self, first: object, last: object = None) -> None:
        self._value = ""

    def insert(self, index: object, text: str) -> None:
        self._value += text

    def pack(self, *args: object, **kwargs: object) -> FakeEntry:
        return self

    def bind(self, *args: object, **kwargs: object) -> None:
        pass

    def configure(self, *args: object, **kwargs: object) -> None:
        pass

    config = configure

    def focus_set(self) -> None:
        pass

    def focus_force(self) -> None:
        pass


class FakeText(FakeEntry):
    """A functional multi-line text box (``get`` ignores the index range)."""

    def get(self, start: object = None, end: object = None) -> str:
        return self._value


class FakeListbox:
    """A functional listbox tracking items and the current selection."""

    def __init__(self, *args: object, **kwargs: object) -> None:
        self._items: list[str] = []
        self._sel: tuple[int, ...] = ()

    def delete(self, first: object, last: object = None) -> None:
        self._items = []

    def insert(self, index: object, text: str) -> None:
        self._items.append(text)

    def curselection(self) -> tuple[int, ...]:
        return self._sel

    def selection_set(self, index: int) -> None:
        self._sel = (index,)

    def selection_clear(self, first: object, last: object = None) -> None:
        self._sel = ()

    def pack(self, *args: object, **kwargs: object) -> FakeListbox:
        return self

    def bind(self, *args: object, **kwargs: object) -> None:
        pass


class FakeWidget:
    """A generic no-op widget for Frame/Label/Button/OptionMenu."""

    def __init__(self, *args: object, **kwargs: object) -> None:
        pass

    def pack(self, *args: object, **kwargs: object) -> FakeWidget:
        return self

    def place(self, *args: object, **kwargs: object) -> FakeWidget:
        return self

    def configure(self, *args: object, **kwargs: object) -> FakeWidget:
        return self

    config = configure

    def bind(self, *args: object, **kwargs: object) -> None:
        pass


_FAKE_TK = SimpleNamespace(
    END="end",
    TclError=_FakeTclError,
    StringVar=FakeVar,
    Frame=FakeWidget,
    Label=FakeWidget,
    Button=FakeWidget,
    OptionMenu=FakeWidget,
    Entry=FakeEntry,
    Text=FakeText,
    Listbox=FakeListbox,
    Event=object,
)

# Every mixin module the gate window is built from imports ``tkinter``
# independently; all of them must see the fake so ``tk.TclError`` etc. are the
# catchable ``_FakeTclError`` everywhere a test raises it.
_GATE_TK_MODULES = (
    _gatelock,
    _gatelock_core,
    _gatelock_window,
    _gatelock_nutrition,
    _gatelock_mealflow,
    _gatelock_ui,
)


@pytest.fixture
def gate() -> Iterator[MealGate]:
    """Build a demo gate whose widgets are functional fakes."""
    with ExitStack() as stack:
        for module in _GATE_TK_MODULES:
            stack.enter_context(patch.object(module, "tk", _FAKE_TK))
        yield MealGate(demo_mode=True)


def _nutrition(kcal: float = 100, grams: float = 100) -> Nutrition:
    """A simple reference nutrition for driving the gate form."""
    return Nutrition(kcal, 10, 20, 5, grams, "food bank")
