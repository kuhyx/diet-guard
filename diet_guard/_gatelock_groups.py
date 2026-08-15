"""Presenting the gate's N per-monitor copies as if they were one form.

Since gatelock v0.2.0 the lock builds one window per live output, so the gate
is laid out once per monitor and the controller must drive all of them at
once. The individual per-widget groups -- and the rationale for which kinds of
state can share a Tk variable and which genuinely diverge -- live in
:mod:`._gatelock_widgetgroups`; this half assembles them into the single
``GateWidgetsGroup`` the controller drives, so each file stays under the
repo's 250-line limit.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from diet_guard._gatelock_widgetgroups import (
    EntryGroup,
    ListboxGroup,
    TextGroup,
    WidgetGroup,
)

if TYPE_CHECKING:
    import tkinter as tk

    from diet_guard._gatelock_ui_types import GateVars, GateWidgets

__all__ = [
    "EntryGroup",
    "GateWidgetsGroup",
    "ListboxGroup",
    "MacroGroup",
    "TextGroup",
    "WidgetGroup",
]


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
    def macros(self) -> MacroGroup:
        """The four macro entries, each over its shared variable."""
        cells = [bundle.macros for bundle in self._bundles]
        return MacroGroup(
            kcal=EntryGroup([c.kcal for c in cells], self._vars.entries.kcal),
            protein=EntryGroup([c.protein for c in cells], self._vars.entries.protein),
            carbs=EntryGroup([c.carbs for c in cells], self._vars.entries.carbs),
            fat=EntryGroup([c.fat for c in cells], self._vars.entries.fat),
        )
