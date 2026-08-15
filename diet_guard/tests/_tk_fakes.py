"""Functional fake Tk widgets for the gate's display-free tests.

Extracted from ``conftest.py`` purely for size: the widget tree the gate builds
now spans several modules plus ``gatelock``, and the fakes grew past this repo's
500-line file cap when the scroll viewport and the radio-button unit selector
were added.

Stays under ``tests/`` deliberately. It was briefly moved into the package to
satisfy the ``test_*.py`` naming hook, but that lost the ruff ``ARG`` exemption
that ``**/tests/**`` already grants -- and a fake widget's whole job is to
accept arguments it ignores. Weakening ruff for package code to accommodate
test scaffolding is the wrong trade; excluding one clearly-named support file
from a naming convention is the cheaper one.

The fakes are *functional* where behaviour matters -- selecting a radio button
really sets its variable and fires its command, and the canvas really tracks a
scroll offset -- so a test can drive the gate the way a keyboard user now can,
rather than merely asserting that a widget was constructed.
"""

from __future__ import annotations

from types import SimpleNamespace

from diet_guard.tests._tk_fakes_canvas import FakeCanvas, FakeScrollbar
from diet_guard.tests._tk_fakes_containers import (
    FakeNotebook,
    FakeRadiobutton,
    FakeStyle,
    FakeWidget,
)

# Imported by name so `from _tk_fakes import X` keeps working for every fake,
# and so `_gate_fixtures`'s `_FAKE_TK`/`_FAKE_TTK` import has one home. Listed
# explicitly (rather than left as incidental imports) because ruff would
# otherwise strip the re-exports as unused -- and the identity assertion in
# `test_gate_tk_modules.py` is what catches it if one ever goes missing.
__all__ = [
    "_FAKE_TK",
    "_FAKE_TTK",
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
]


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
    """A functional one-line entry (delete clears, insert appends).

    ``configure``/``config`` record their kwargs into ``configured``, so a
    test can assert on a read-only/editable state toggle the same way it
    would with :class:`FakeWidget`.
    """

    def __init__(self, *args: object, **kwargs: object) -> None:
        self._value = ""
        self.configured: dict[str, object] = dict(kwargs)

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
        self.configured.update(kwargs)

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


_FAKE_TK = SimpleNamespace(
    END="end",
    TclError=_FakeTclError,
    StringVar=FakeVar,
    Frame=FakeWidget,
    Label=FakeWidget,
    Button=FakeWidget,
    OptionMenu=FakeWidget,
    Radiobutton=FakeRadiobutton,
    Entry=FakeEntry,
    Text=FakeText,
    Listbox=FakeListbox,
    Canvas=FakeCanvas,
    Scrollbar=FakeScrollbar,
    Misc=FakeWidget,
    Event=object,
)

_FAKE_TTK = SimpleNamespace(Notebook=FakeNotebook, Style=FakeStyle)

# Every mixin module the gate window is built from imports ``tkinter``
# independently; all of them must see the fake so ``tk.TclError`` etc. are the
# catchable ``_FakeTclError`` everywhere a test raises it.
