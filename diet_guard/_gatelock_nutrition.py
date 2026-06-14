"""Reference-to-total nutrition model and food lookup for the MealGate gate.

Split out of :mod:`._gatelock` to keep that module under the repo's 500-line
limit.  ``_GateNutrition`` extends
:class:`~python_pkg.diet_guard._gatelock_core._GateCore` with the
"reference -> total" nutrition maths -- the label macros describe one basis
(per 100 g or per item), and how much was eaten scales that reference into
what gets logged -- plus the live preview/projection and the
autocomplete/lookup flow that fills the reference fields from banked foods,
staples, or Open Food Facts.
"""

from __future__ import annotations

import tkinter as tk

from python_pkg.diet_guard._budget import BudgetError, daily_budget
from python_pkg.diet_guard._estimator import Nutrition, scale_nutrition
from python_pkg.diet_guard._gatelock_core import _GateCore
from python_pkg.diet_guard._gatelock_ui import (
    DEFAULT_PER_GRAMS,
    SUGGESTION_ROWS,
    UNIT_ITEMS,
)
from python_pkg.diet_guard._portions import DEFAULT_ITEM_GRAMS, estimate_unit_grams
from python_pkg.diet_guard._resolve import suggest_foods
from python_pkg.diet_guard._state import today_total_kcal


def _format_preview(nutrition: Nutrition) -> str:
    """Render the one-line "this is what will be logged" preview."""
    portion = f" · {nutrition.grams:g}g" if nutrition.grams else ""
    return (
        f"→ {nutrition.kcal:g} kcal · "
        f"P{nutrition.protein_g:g} C{nutrition.carbs_g:g} F{nutrition.fat_g:g}"
        f"{portion} · {nutrition.source}"
    )


class _GateNutrition(_GateCore):
    """Reference->total nutrition maths, live preview, and food lookup."""

    # -- the reference -> total model --------------------------------------

    def _reference_nutrition(self) -> Nutrition | None:
        """Return the label values as a Nutrition, or None if calories are blank.

        This is the *reference* (macros for one basis -- per 100 g, or per item),
        not the total: how much was eaten scales it in :meth:`_current_nutrition`.
        """
        values = self._macro_values()
        if values is None or values[0] is None:
            return None
        return Nutrition(
            kcal=values[0],
            protein_g=values[1] or 0.0,
            carbs_g=values[2] or 0.0,
            fat_g=values[3] or 0.0,
            grams=self._basis_grams(),
            source=self._state.source,
        )

    def _current_nutrition(self) -> Nutrition | None:
        """Return exactly what would be logged now, or None if not yet resolvable.

        The label reference scaled to the amount eaten.  With no amount yet, the
        reference itself stands in (one basis portion), so the preview is never
        empty just because an amount has not been typed.
        """
        reference = self._reference_nutrition()
        if reference is None:
            return None
        eaten = self._eaten_grams()
        return scale_nutrition(reference, eaten) if eaten is not None else reference

    def _refresh_preview(self) -> None:
        """Recompute the preview line and the live calorie projection."""
        nutrition = self._current_nutrition()
        self._vars.preview.set(
            _format_preview(nutrition) if nutrition is not None else ""
        )
        self._refresh_projection()

    def _refresh_projection(self) -> None:
        """Show consumed / budget / remaining, and what is left after this item.

        This answers, as the calories are typed, the four numbers the user asked
        to see together: how much is already eaten today, the day's goal, how
        much is left now, and how much would be left *after* logging the food
        currently in the form.  With no budget sealed it degrades to the running
        total plus this item's calories, so it is always informative.
        """
        consumed = today_total_kcal()
        nutrition = self._current_nutrition()
        this_kcal = nutrition.kcal if nutrition is not None else 0.0
        try:
            budget = daily_budget()
        except (BudgetError, OSError):
            tail = f" · this item {this_kcal:g} kcal" if this_kcal else ""
            self._vars.projection.set(f"Consumed {consumed:g} kcal today{tail}")
            return
        left = round(budget - consumed, 1)
        base = f"Consumed {consumed:g} / {budget:g} kcal · {left:g} left"
        if this_kcal:
            after = round(budget - consumed - this_kcal, 1)
            self._vars.projection.set(f"{base}   →   after this item: {after:g} left")
        else:
            self._vars.projection.set(base)

    # -- autocomplete / lookup ---------------------------------------------

    def _on_desc_keyrelease(self, _event: tk.Event[tk.Misc]) -> None:
        """Refresh suggestions; in items mode, show the piece's weight."""
        query = self._get_desc()
        self._populate_suggestions(query)
        # In items mode, surface a recognised piece's weight as it is typed, so
        # "apple" visibly becomes "≈ 182 g" rather than a hidden assumption.
        if self._vars.unit.get() == UNIT_ITEMS:
            grams = estimate_unit_grams(query)
            if grams is not None:
                self._set_entry(self._widgets.per_entry, f"{grams:g}")
        self._refresh_preview()

    def _populate_suggestions(self, query: str) -> None:
        """Fill the picker with banked foods and matching staples for ``query``."""
        self._state.suggestion_mode = "bank"
        self._state.suggestions = suggest_foods(query, limit=SUGGESTION_ROWS)
        self._widgets.suggestion_box.delete(0, tk.END)
        for name, nutrition in self._state.suggestions:
            self._widgets.suggestion_box.insert(
                tk.END, f"{name}  ({nutrition.kcal:g} kcal)"
            )

    def _show_candidates(self, candidates: list[tuple[str, Nutrition]]) -> None:
        """Fill the picker with looked-up alternatives to choose from."""
        self._state.suggestion_mode = "candidates"
        self._state.suggestions = candidates
        self._widgets.suggestion_box.delete(0, tk.END)
        for label, nutrition in candidates:
            self._widgets.suggestion_box.insert(
                tk.END,
                f"{label}  ({nutrition.kcal:g} kcal · {nutrition.grams:g}g)",
            )

    def _on_suggestion_select(self, _event: tk.Event[tk.Misc]) -> None:
        """Fill the form from the picked suggestion."""
        selection = self._widgets.suggestion_box.curselection()
        if not selection:
            return
        index = selection[0]
        if index >= len(self._state.suggestions):
            return
        name, nutrition = self._state.suggestions[index]
        # Banked/staple entries carry a name, so adopt it; OFF products only
        # supply macros and must not overwrite what the user typed.
        if self._state.suggestion_mode == "bank":
            self._apply_reference(nutrition, name=name)
        else:
            self._apply_reference(nutrition)

    def _apply_reference(
        self, nutrition: Nutrition, *, name: str | None = None
    ) -> None:
        """Adopt ``nutrition`` as the reference and mirror it into the fields.

        In grams mode the food's own weight is the "per" basis and its macros
        fill the fields directly.  In items mode the per-100 g reference is
        converted to a single piece (its weight shown in "per"), so the macro
        fields read *per item*.  The amount eaten does the scaling either way.
        """
        self._state.source = nutrition.source
        self._state.last_reference = nutrition
        if name is not None:
            self._set_desc(name)
        if self._vars.unit.get() == UNIT_ITEMS:
            grams = estimate_unit_grams(self._get_desc())
            unit = grams if grams is not None else DEFAULT_ITEM_GRAMS
            self._set_entry(self._widgets.per_entry, f"{unit:g}")
            self._fill_macro_fields(scale_nutrition(nutrition, unit))
        else:
            basis = nutrition.grams or DEFAULT_PER_GRAMS
            self._set_entry(self._widgets.per_entry, f"{basis:g}")
            self._fill_macro_fields(nutrition)
            # Default the eaten amount to one reference portion so a pick is
            # immediately loggable (grams mode only -- items need a count).
            if not self._widgets.amount_entry.get().strip() and nutrition.grams:
                self._set_entry(self._widgets.amount_entry, f"{nutrition.grams:g}")
        self._refresh_preview()

    # -- live recompute -----------------------------------------------------

    def _on_amount_change(self, _event: tk.Event[tk.Misc]) -> None:
        """Recompute the preview when the amount or basis changes.

        Crucially this does *not* rewrite the macro fields: those hold the label
        reference, and only the previewed/logged total reflects the new amount.
        """
        self._refresh_preview()

    def _on_unit_change(self, _value: str) -> None:
        """Switch grams<->items, re-expressing the picked food in the new basis.

        The macro fields mean different things in each mode (per 100 g / per
        portion vs per item).  When a food was picked or looked up, its stored
        reference is re-applied so toggling converts the values back and forth
        losslessly.  A hand-typed (manual) entry has no clean reference to
        convert, so its fields are cleared to be re-entered in the new basis
        rather than silently reinterpreted.
        """
        self._relabel_basis()
        self._widgets.amount_entry.delete(0, tk.END)
        if self._state.last_reference is not None:
            self._apply_reference(self._state.last_reference)
            return
        for entry in self._macro_entries():
            entry.delete(0, tk.END)
        self._reset_per_default()
        self._state.source = "manual"
        self._refresh_preview()

    def _on_macro_edit(self, _event: tk.Event[tk.Misc]) -> None:
        """A hand-edited macro becomes the manual reference from here on.

        Editing a macro by hand invalidates the picked food's stored reference:
        the fields no longer match it, so a later unit toggle must not snap them
        back to it.
        """
        self._state.source = "manual"
        self._state.last_reference = None
        self._refresh_preview()
