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


class FakeWidget:
    """A generic no-op widget for Frame/Label/Button/OptionMenu.

    ``configure``/``config`` record their kwargs into ``configured`` (rather
    than discarding them) so a test can assert on a widget's last-set color
    or text, e.g. the calendar's per-cell status coloring.
    """

    def __init__(self, *args: object, **kwargs: object) -> None:
        self.configured: dict[str, object] = dict(kwargs)

    def pack(self, *args: object, **kwargs: object) -> FakeWidget:
        return self

    def place(self, *args: object, **kwargs: object) -> FakeWidget:
        return self

    def grid(self, *args: object, **kwargs: object) -> FakeWidget:
        return self

    def configure(self, *args: object, **kwargs: object) -> FakeWidget:
        self.configured.update(kwargs)
        return self

    config = configure

    def bind(self, *args: object, **kwargs: object) -> None:
        pass

    def register(self, func: object) -> object:
        """Stand in for Tk's Tcl-command registration: return the callable as-is."""
        return func

    def winfo_children(self) -> list[object]:
        """No children: the fakes are not a real widget tree."""
        return []

    def winfo_toplevel(self) -> FakeWidget:
        return self

    def update_idletasks(self) -> None:
        pass

    def cget(self, key: str) -> object:
        return self.configured.get(key, "")

    # Geometry queries. The scroll viewport asks for these to size itself and
    # to decide whether content still fits; zero means "nothing measured yet",
    # which is the honest answer for a fake with no layout.
    def winfo_reqwidth(self) -> int:
        return 0

    def winfo_reqheight(self) -> int:
        return 0

    def winfo_width(self) -> int:
        return 0

    def winfo_height(self) -> int:
        return 0

    def winfo_rooty(self) -> int:
        return 0

    def winfo_screenwidth(self) -> int:
        return 1366

    def winfo_screenheight(self) -> int:
        return 768


class FakeNotebook(FakeWidget):
    """A functional ``ttk.Notebook``: tracks added tabs and the selection."""

    def __init__(self, *args: object, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)
        self.tabs: list[tuple[object, str]] = []
        self._selected = 0
        self.traversal_enabled = False

    def add(self, child: object, *, text: str = "") -> None:
        self.tabs.append((child, text))

    def enable_traversal(self) -> None:
        """Record that Ctrl+Tab / Ctrl+PageDown traversal was requested.

        Tracked rather than ignored so a test can assert it happened: ttk only
        installs those toplevel bindings on request, and forgetting the call
        leaves the tab-switching keys silently dead.
        """
        self.traversal_enabled = True

    def select(self, tab_id: object = None) -> int | None:
        if tab_id is None:
            return self._selected
        if isinstance(tab_id, int):
            self._selected = tab_id
        else:
            for index, (child, _label) in enumerate(self.tabs):
                if child is tab_id:
                    self._selected = index
                    break
        return None


class FakeRadiobutton(FakeWidget):
    """A functional ``tk.Radiobutton``: selecting sets the var and fires.

    Functional rather than a no-op because this is the gate's grams/items unit
    selector, which used to be a keyboard-unreachable ``OptionMenu``. A test
    needs to be able to drive it the way a keyboard user now can.
    """

    def __init__(self, *args: object, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)
        self.value = kwargs.get("value")
        self._variable = kwargs.get("variable")
        self._command = kwargs.get("command")

    def invoke(self) -> None:
        """Select this option, as Space/Return does on a real Radiobutton."""
        if self._variable is not None and hasattr(self._variable, "set"):
            self._variable.set(self.value)
        if callable(self._command):
            self._command()

    select = invoke


class FakeScrollbar(FakeWidget):
    """A ``tk.Scrollbar`` stand-in that records the thumb position."""

    def __init__(self, *args: object, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)
        self.fractions: tuple[str, ...] = ()

    def set(self, *fractions: str) -> None:
        self.fractions = fractions


class FakeCanvas(FakeWidget):
    """A functional ``tk.Canvas`` stand-in for ``gatelock.ScrollableSurface``.

    Tracks the scroll offset so a test can assert the viewport actually moved,
    which is the whole point of the widget being there: the gate's content can
    exceed a 768px screen, and before the viewport existed the overflow was
    silently clipped off both edges at once.
    """

    def __init__(self, *args: object, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)
        self.items: list[object] = []
        self.offset = 0.0
        self._children: list[object] = []

    def create_window(self, *args: object, **kwargs: object) -> int:
        window = kwargs.get("window")
        if window is not None:
            self.items.append(window)
            self._children.append(window)
        return len(self.items)

    def itemconfigure(self, *args: object, **kwargs: object) -> None:
        pass

    def coords(self, *args: object, **kwargs: object) -> None:
        pass

    def bbox(self, *_args: object) -> tuple[int, int, int, int]:
        return (0, 0, 0, 0)

    def yview(self) -> tuple[float, float]:
        return (self.offset, 1.0)

    def yview_scroll(self, number: int, _what: str) -> None:
        self.offset = max(0.0, self.offset + number)

    def yview_moveto(self, fraction: float) -> None:
        self.offset = fraction

    def canvasy(self, screen_y: float) -> float:
        return screen_y

    def winfo_children(self) -> list[object]:
        return list(self._children)

    def winfo_height(self) -> int:
        return 0

    def winfo_toplevel(self) -> FakeWidget:
        return self

    def update_idletasks(self) -> None:
        pass

    def cget(self, key: str) -> object:
        return self.configured.get(key, "")


class FakeStyle:
    """A no-op stand-in for ``ttk.Style`` -- records calls, applies nothing."""

    def __init__(self, *args: object, **kwargs: object) -> None:
        self.theme: str | None = None
        self.configured: dict[str, dict[str, object]] = {}

    def theme_use(self, theme_name: str) -> None:
        self.theme = theme_name

    def configure(self, style_name: str, **kwargs: object) -> None:
        self.configured.setdefault(style_name, {}).update(kwargs)

    def map(self, style_name: str, **kwargs: object) -> None:
        self.configured.setdefault(style_name, {}).update(kwargs)


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
