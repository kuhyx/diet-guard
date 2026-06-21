"""Shared base class and state for the MealGate gate.

Split out of :mod:`._gatelock` to keep that module under the repo's 500-line
limit.  ``_GateCore`` holds the leaf widget/field helpers that every other
gatelock mixin (`_gatelock_nutrition`, `_gatelock_mealflow`) derives from,
plus the small dataclass (`_GateState`) that :mod:`._gatelock` itself depends
on. The window/lock mechanics and the ``GateRoot`` Tk root subclass that used
to live here now come from the shared ``gatelock`` package.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import logging
import tkinter as tk
from typing import TYPE_CHECKING

from python_pkg.diet_guard._gatelock_ui import (
    BASIS_PREFIX_GRAMS,
    BASIS_PREFIX_ITEMS,
    DEFAULT_PER_GRAMS,
    UNIT_ITEMS,
    GateVars,
    GateWidgets,
)
from python_pkg.diet_guard._portions import DEFAULT_ITEM_GRAMS, estimate_unit_grams
from python_pkg.diet_guard._slots import slot_label

if TYPE_CHECKING:
    from collections.abc import Callable

    from gatelock import GateRoot

    from python_pkg.diet_guard._estimator import Nutrition
    from python_pkg.diet_guard._meal import MealItem

_logger = logging.getLogger(__name__)


def _safe_float(raw: str) -> float | None:
    """Return ``raw`` parsed as a float, or None if it is blank/non-numeric."""
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


@dataclass
class _GateState:
    """Mutable logical state of the in-progress entry (no widget references).

    ``source`` is the provenance of the values in the reference fields
    ("manual", "food bank", "staple: apple", ...).  It is a label only -- the
    maths read the fields directly -- so there is no second copy of the numbers
    to desync; it resets to "manual" the moment a macro is hand-edited.
    ``suggestions`` pairs each listed pick with its nutrition, and
    ``suggestion_mode`` says whether picking one overwrites the description
    (bank entries are the user's own names) or only fills macros (OFF products).
    ``last_reference`` is the natural-basis nutrition of the food last picked
    or looked up, kept so a grams<->items toggle can re-express it losslessly;
    it is cleared the moment a macro is hand-edited.  ``meal_items`` accumulates
    the parts of a multi-item meal before they are logged as one summed entry.
    """

    source: str = "manual"
    suggestions: list[tuple[str, Nutrition]] = field(default_factory=list)
    suggestion_mode: str = "bank"
    last_reference: Nutrition | None = None
    meal_items: list[MealItem] = field(default_factory=list)


class _GateCore:
    """Leaf widget/field helpers shared by every MealGate mixin.

    Declares the attributes that
    :class:`~python_pkg.diet_guard._gatelock.MealGate` sets up in ``__init__``
    and ``_build`` so subclasses can reference them without tripping pylint's
    no-member check.
    """

    root: GateRoot
    demo_mode: bool
    _pending: list[int]
    _state: _GateState
    _vars: GateVars
    _widgets: GateWidgets
    close: Callable[[], None]

    # -- description field ---------------------------------------------------

    def _get_desc(self) -> str:
        """Return the description text, trimmed (a Text always trails a newline)."""
        return self._widgets.desc_text.get("1.0", "end-1c").strip()

    def _set_desc(self, value: str) -> None:
        """Replace the description box's contents with ``value``."""
        self._widgets.desc_text.delete("1.0", tk.END)
        if value:
            self._widgets.desc_text.insert("1.0", value)

    def _macro_entries(self) -> tuple[tk.Entry, ...]:
        """Return the four numeric entry widgets in (kcal, P, C, F) order."""
        macros = self._widgets.macros
        return (macros.kcal, macros.protein, macros.carbs, macros.fat)

    # -- slot walk --------------------------------------------------------------

    def _refresh_slot_header(self) -> None:
        """Update the header to prompt for the slot now being collected."""
        total = len(self._pending)
        if total == 0:
            self._vars.slot_header.set("All meals logged.")
            return
        slot = self._pending[0]
        position = "" if total == 1 else f"  (1 of {total} remaining)"
        self._vars.slot_header.set(f"Log your {slot_label(slot)} meal{position}")

    def _reset_per_default(self) -> None:
        """Set the "per" field to the basis default for the current unit."""
        self._widgets.per_entry.delete(0, tk.END)
        if self._vars.unit.get() == UNIT_ITEMS:
            grams = estimate_unit_grams(self._get_desc())
            self._widgets.per_entry.insert(
                0, f"{grams if grams is not None else DEFAULT_ITEM_GRAMS:g}"
            )
        else:
            self._widgets.per_entry.insert(0, f"{DEFAULT_PER_GRAMS:g}")

    def _relabel_basis(self) -> None:
        """Point the per-basis label at grams or per-item for the current unit."""
        items = self._vars.unit.get() == UNIT_ITEMS
        self._widgets.basis_prefix.config(
            text=BASIS_PREFIX_ITEMS if items else BASIS_PREFIX_GRAMS,
        )

    # -- field helpers ------------------------------------------------------

    def _basis_grams(self) -> float:
        """Return the grams the label macros describe (per 100 g or per item).

        Honours an explicit "per" value when the user has typed one; otherwise
        falls back to one piece's weight in items mode, or 100 g in grams mode.
        """
        typed = _safe_float(self._widgets.per_entry.get().strip())
        if typed is not None and typed > 0:
            return typed
        if self._vars.unit.get() == UNIT_ITEMS:
            grams = estimate_unit_grams(self._get_desc())
            return grams if grams is not None else DEFAULT_ITEM_GRAMS
        return DEFAULT_PER_GRAMS

    def _eaten_grams(self) -> float | None:
        """Return how many grams were eaten, or None if no amount is entered.

        In grams mode the amount *is* the grams; in items mode it is multiplied
        by one piece's weight (the "per" field), so "5 apples" becomes a weight.
        """
        amount = _safe_float(self._widgets.amount_entry.get().strip())
        if amount is None:
            return None
        if self._vars.unit.get() == UNIT_ITEMS:
            return amount * self._basis_grams()
        return amount

    def _macro_values(self) -> tuple[float | None, ...] | None:
        """Return ``(kcal, P, C, F)`` floats/None, or None if any is non-numeric."""
        values: list[float | None] = []
        for entry in self._macro_entries():
            raw = entry.get().strip()
            parsed = _safe_float(raw)
            if raw and parsed is None:
                return None
            values.append(parsed)
        return tuple(values)

    def _set_entry(self, entry: tk.Entry, value: str) -> None:
        """Replace an entry's contents with ``value``."""
        entry.delete(0, tk.END)
        entry.insert(0, value)

    def _fill_macro_fields(self, nutrition: Nutrition) -> None:
        """Write a nutrition's macros into the kcal/P/C/F fields."""
        pairs = zip(
            self._macro_entries(),
            (
                nutrition.kcal,
                nutrition.protein_g,
                nutrition.carbs_g,
                nutrition.fat_g,
            ),
            strict=True,
        )
        for entry, value in pairs:
            self._set_entry(entry, f"{value:g}")
