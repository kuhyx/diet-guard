"""Container and notebook fakes for the gate's display-free tests.

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

__all__ = [
    "FakeNotebook",
    "FakeRadiobutton",
    "FakeStyle",
    "FakeWidget",
]


class FakeWidget:
    """A generic no-op widget for Frame/Label/Button/OptionMenu.

    ``configure``/``config`` record their kwargs into ``configured`` (rather
    than discarding them) so a test can assert on a widget's last-set color
    or text, e.g. the calendar's per-cell status coloring.
    """

    def __init__(self, *args: object, **kwargs: object) -> None:
        self.configured: dict[str, object] = dict(kwargs)
        self.packed = False

    def pack(self, *args: object, **kwargs: object) -> FakeWidget:
        self.packed = True
        return self

    def pack_forget(self, *args: object, **kwargs: object) -> None:
        """Un-pack. The viewport hides its scrollbar whenever content fits."""
        self.packed = False

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

    def focus_get(self) -> None:
        """Nothing holds focus in a fake tree."""

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
