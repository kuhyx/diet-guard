"""Presenting the gate's N per-monitor copies as if they were one form.

Since gatelock v0.2.0 the lock builds one window per live output, so the gate
is laid out once per monitor and the controller must drive all of them at
once. Three different kinds of state show up, and each needs a different
answer:

* **Display fields** already fan out for free. ``GateVars`` holds
  root-mastered ``StringVar``s bound to labels, so one ``set`` repaints every
  monitor with no help from this module.
* **Entries** are made variable-backed here for the same reason: typing an
  amount on whichever screen the user is looking at is then the same text
  everywhere, and reading it back needs no idea which monitor that was.
* **The description box and the suggestion list** cannot share a variable --
  ``tk.Text`` and ``tk.Listbox`` have none. Their copies genuinely diverge, so
  reads answer from whichever copy the user actually touched.

The alternative -- laying the gate out on the primary monitor only -- was
rejected: the whole point of per-output locking is that the user does not
have to hunt for the screen the form landed on.
"""

from __future__ import annotations

import contextlib
import tkinter as tk
from typing import TYPE_CHECKING, Generic, TypeVar

if TYPE_CHECKING:
    from collections.abc import Callable, Iterator

    from diet_guard._gatelock_ui_types import GateVars, GateWidgets

_W = TypeVar("_W", bound=tk.Misc)
"""The widget each group mirrors, so a subclass keeps its own methods typed."""


class WidgetGroup(Generic[_W]):
    """One logical widget, mirrored onto every monitor."""

    def __init__(self, widgets: list[_W]) -> None:
        """Wrap the per-monitor copies of one widget."""
        self._widgets = widgets

    def __iter__(self) -> Iterator[_W]:
        """Iterate the per-monitor copies."""
        return iter(self._widgets)

    @property
    def first(self) -> _W:
        """The primary monitor's copy, for reads that cannot fan out."""
        return self._widgets[0]

    def config(self, **kwargs: str) -> None:
        """Apply the same configuration to every copy."""
        for widget in self._widgets:
            with contextlib.suppress(tk.TclError):
                widget.configure(**kwargs)

    configure = config

    def bind(
        self, sequence: str, callback: Callable[[tk.Event[tk.Misc]], object]
    ) -> None:
        """Bind the same handler on every copy.

        Tk's ``bind`` replaces an existing binding for the same sequence, so
        re-wiring after an output comes back is idempotent rather than
        stacking duplicate handlers.
        """
        for widget in self._widgets:
            with contextlib.suppress(tk.TclError):
                widget.bind(sequence, callback)

    def focus_set(self) -> None:
        """Focus the first copy that still exists.

        Focus is singular by nature: there is one keyboard, so this picks the
        first live copy rather than fanning out.
        """
        for widget in self._widgets:
            with contextlib.suppress(tk.TclError):
                widget.focus_set()
                return

    def focus_force(self) -> None:
        """Force focus onto the first copy that still exists."""
        for widget in self._widgets:
            with contextlib.suppress(tk.TclError):
                widget.focus_force()
                return


class EntryGroup(WidgetGroup[tk.Entry]):
    """A single-line entry, mirrored onto every monitor over one variable.

    Because every copy is bound to the same ``StringVar``, reads and writes go
    through the variable rather than the widgets: the copies cannot disagree.
    """

    def __init__(self, widgets: list[tk.Entry], var: tk.StringVar) -> None:
        """Wrap the per-monitor entries and the variable behind them."""
        super().__init__(widgets)
        self._var = var

    def get(self) -> str:
        """Return the shared text, whichever monitor it was typed on."""
        return self._var.get()

    def delete(self, _first: int | str, _last: int | str | None = None) -> None:
        """Clear the shared text on every monitor."""
        self._var.set("")

    def insert(self, _index: int | str, value: str) -> None:
        """Set the shared text on every monitor.

        Only ever used here to fill an empty field, so "insert" and "set" are
        the same operation; taking the index keeps the tk-shaped call sites
        unchanged.
        """
        self._var.set(value)


class TextGroup(WidgetGroup[tk.Text]):
    """The description box, mirrored onto every monitor.

    ``tk.Text`` has no ``textvariable``, so the copies really do diverge. The
    user types into exactly one of them; reads return that one, which keeps
    "log the meal on whichever screen you are looking at" true.
    """

    def get(self, start: str, end: str) -> str:
        """Return the content of whichever copy was actually typed into."""
        for widget in self._widgets:
            with contextlib.suppress(tk.TclError):
                content = widget.get(start, end)
                if content.strip():
                    return str(content)
        return str(self._widgets[0].get(start, end))

    def delete(self, start: str, end: str) -> None:
        """Clear every copy."""
        for widget in self._widgets:
            with contextlib.suppress(tk.TclError):
                widget.delete(start, end)

    def insert(self, index: str, value: str) -> None:
        """Write the same content into every copy."""
        for widget in self._widgets:
            with contextlib.suppress(tk.TclError):
                widget.insert(index, value)


class ListboxGroup(WidgetGroup[tk.Listbox]):
    """The suggestion picker, mirrored onto every monitor.

    A ``Listbox`` selection is per-widget, so the selected index is read from
    whichever copy has one -- the monitor the user clicked on.
    """

    def delete(self, first: int | str, last: int | str | None = None) -> None:
        """Clear every copy."""
        for widget in self._widgets:
            with contextlib.suppress(tk.TclError):
                widget.delete(first, last)

    def insert(self, index: int | str, *values: str) -> None:
        """Append the same entries to every copy."""
        for widget in self._widgets:
            with contextlib.suppress(tk.TclError):
                widget.insert(index, *values)

    def selection_set(self, first: int, last: int | None = None) -> None:
        """Select the same row on every copy.

        Programmatic selection (a keyboard pick, or a test) has to reach all
        of them; a *mouse* pick lands on one copy, which is what
        ``curselection`` reads back.
        """
        for widget in self._widgets:
            with contextlib.suppress(tk.TclError):
                if last is None:
                    widget.selection_set(first)
                else:
                    widget.selection_set(first, last)

    def selection_clear(self, first: int, last: int | None = None) -> None:
        """Clear the selection on every copy."""
        for widget in self._widgets:
            with contextlib.suppress(tk.TclError):
                if last is None:
                    widget.selection_clear(first)
                else:
                    widget.selection_clear(first, last)

    def curselection(self) -> tuple[int, ...]:
        """Return the selection from whichever copy the user clicked."""
        for widget in self._widgets:
            with contextlib.suppress(tk.TclError):
                selection = widget.curselection()
                if selection:
                    return tuple(selection)
        return ()

    def size(self) -> int:
        """Number of rows; identical on every copy, so read the primary."""
        return int(self._widgets[0].size())


class MacroGroup:
    """The four macro entries, each mirrored onto every monitor."""

    def __init__(
        self,
        kcal: EntryGroup,
        protein: EntryGroup,
        carbs: EntryGroup,
        fat: EntryGroup,
    ) -> None:
        """Bundle the four macro entry groups."""
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat


class GateWidgetsGroup:
    """Every per-monitor copy of the gate, driven as if it were one form.

    ``_build_tabs`` produces one ``GateWidgets`` per live output and they are
    added here; the controller then drives this exactly as it drove a single
    bundle before per-output locking existed.
    """

    def __init__(self, vars_: GateVars) -> None:
        """Start empty; surfaces are added as outputs come up."""
        self._vars = vars_
        self._bundles: list[GateWidgets] = []
        self._outputs: list[str] = []

    def add(self, widgets: GateWidgets, output_name: str) -> None:
        """Register the bundle built for one newly-live output."""
        self._bundles.append(widgets)
        self._outputs.append(output_name)

    def discard(self, output_name: str) -> None:
        """Forget the bundle for an output that went dark."""
        kept = [
            (bundle, name)
            for bundle, name in zip(self._bundles, self._outputs, strict=True)
            if name != output_name
        ]
        self._bundles = [bundle for bundle, _ in kept]
        self._outputs = [name for _, name in kept]

    @property
    def bundles(self) -> list[GateWidgets]:
        """Every per-monitor bundle; empty until the lock builds them."""
        return list(self._bundles)

    def _each(self, name: str) -> list[tk.Misc]:
        """Collect one named widget from every monitor's bundle."""
        return [getattr(bundle, name) for bundle in self._bundles]

    @property
    def frame(self) -> WidgetGroup[tk.Misc]:
        """The gate's outer frame on every monitor."""
        return WidgetGroup(self._each("frame"))

    @property
    def desc_text(self) -> TextGroup:
        """The description box on every monitor."""
        return TextGroup(self._each("desc_text"))

    @property
    def suggestion_box(self) -> ListboxGroup:
        """The suggestion picker on every monitor."""
        return ListboxGroup(self._each("suggestion_box"))

    @property
    def status_label(self) -> WidgetGroup[tk.Misc]:
        """The status line on every monitor."""
        return WidgetGroup(self._each("status_label"))

    @property
    def basis_prefix(self) -> WidgetGroup[tk.Misc]:
        """The per-basis prefix label on every monitor."""
        return WidgetGroup(self._each("basis_prefix"))

    @property
    def amount_entry(self) -> EntryGroup:
        """The amount entry, over its shared variable."""
        return EntryGroup(self._each("amount_entry"), self._vars.entries.amount)

    @property
    def per_entry(self) -> EntryGroup:
        """The per-basis entry, over its shared variable."""
        return EntryGroup(self._each("per_entry"), self._vars.entries.per)

    @property
    def meal_name_entry(self) -> EntryGroup:
        """The meal-name entry, over its shared variable."""
        return EntryGroup(self._each("meal_name_entry"), self._vars.entries.meal_name)

    @property
    def macros(self) -> MacroGroup:
        """The four macro entries, each over its shared variable."""
        cells = [bundle.macros for bundle in self._bundles]
        return MacroGroup(
            kcal=EntryGroup([c.kcal for c in cells], self._vars.entries.kcal),
            protein=EntryGroup([c.protein for c in cells], self._vars.entries.protein),
            carbs=EntryGroup([c.carbs for c in cells], self._vars.entries.carbs),
            fat=EntryGroup([c.fat for c in cells], self._vars.entries.fat),
        )
