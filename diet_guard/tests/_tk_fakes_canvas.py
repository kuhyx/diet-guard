"""Canvas and scrollbar fakes for the gate's scroll-viewport tests.

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

from diet_guard.tests._tk_fakes_containers import FakeWidget

__all__ = ["FakeCanvas", "FakeScrollbar"]


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

    def focus_get(self) -> None:
        """Nothing holds focus in a fake tree."""


class FakeScrollbar(FakeWidget):
    """A ``tk.Scrollbar`` stand-in that records the thumb position."""

    def __init__(self, *args: object, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)
        self.fractions: tuple[str, ...] = ()

    def set(self, *fractions: str) -> None:
        self.fractions = fractions
