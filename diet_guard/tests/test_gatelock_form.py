"""Tests for _gatelock.py — the fullscreen log-to-unlock gate window.

Construction, MealGate's gatelock wiring (LockConfig choice, hooks), and the
shared module-level helpers.  The fullscreen/grab/VT-disable mechanics
themselves are tested in the ``gatelock`` package, not here.  The
nutrition/meal-flow tests live in :mod:`test_gatelock_mealflow`; the
functional fake ``tk`` widgets and the ``gate`` fixture live in
``conftest.py`` and are shared by both files.
"""

from __future__ import annotations

from typing import TYPE_CHECKING
from unittest.mock import patch

from diet_guard import (
    _gatelock_ui,
)
from diet_guard._budget import write_budget
from diet_guard._gatelock_ui import DEFAULT_PER_GRAMS
from diet_guard._portions import DEFAULT_ITEM_GRAMS
from diet_guard.tests.conftest import (
    _nutrition,
)

if TYPE_CHECKING:
    from diet_guard._gatelock import (
        MealGate,
    )


class TestFormBasics:
    """Field helpers and the numeric validator."""

    def test_numeric_validator(self) -> None:
        """Blank and numbers are allowed; words are not."""
        assert _gatelock_ui.is_numeric_or_blank("")
        assert _gatelock_ui.is_numeric_or_blank("12.5")
        assert not _gatelock_ui.is_numeric_or_blank("abc")

    def test_desc_get_set(self, gate: MealGate) -> None:
        """The description round-trips through its helpers, trimmed."""
        gate._set_desc("  shoarma  ")
        assert gate._get_desc() == "shoarma"

    def test_desc_return_suppresses_newline(self, gate: MealGate) -> None:
        """Enter in the description submits and returns the break sentinel."""
        gate._set_desc("apple")
        with patch.object(gate, "_on_submit") as submit:
            assert gate._on_desc_return(None) == "break"
        submit.assert_called_once()

    def test_macro_values_non_numeric(self, gate: MealGate) -> None:
        """A non-numeric macro field makes the whole read None."""
        gate._widgets.macros.kcal.insert(0, "abc")
        assert gate._macro_values() is None


class TestBasisAndAmount:
    """Edge branches in the grams/items basis and amount maths."""

    def test_basis_typed_value(self, gate: MealGate) -> None:
        """A typed per-value is honoured directly."""
        gate._set_entry(gate._widgets.per_entry, "50")
        assert gate._basis_grams() == 50

    def test_basis_items_known_staple(self, gate: MealGate) -> None:
        """Items mode with a blank per falls back to the staple weight."""
        gate._widgets.per_entry.delete(0)
        gate._vars.unit.set("items")
        gate._set_desc("apple")
        assert gate._basis_grams() == 182

    def test_basis_items_unknown(self, gate: MealGate) -> None:
        """An unknown item uses the default piece weight."""
        gate._widgets.per_entry.delete(0)
        gate._vars.unit.set("items")
        gate._set_desc("mystery")
        assert gate._basis_grams() == DEFAULT_ITEM_GRAMS

    def test_basis_grams_default(self, gate: MealGate) -> None:
        """Grams mode with a blank per uses the per-100 g default."""
        gate._widgets.per_entry.delete(0)
        assert gate._basis_grams() == DEFAULT_PER_GRAMS

    def test_eaten_grams_none(self, gate: MealGate) -> None:
        """No amount typed yields no eaten weight."""
        assert gate._eaten_grams() is None

    def test_eaten_grams_items(self, gate: MealGate) -> None:
        """Items mode multiplies the count by the per-item weight."""
        gate._vars.unit.set("items")
        gate._set_desc("apple")
        gate._set_entry(gate._widgets.per_entry, "182")
        gate._set_entry(gate._widgets.amount_entry, "5")
        assert gate._eaten_grams() == 5 * 182

    def test_amount_change_refreshes(self, gate: MealGate) -> None:
        """Changing the amount recomputes the preview."""
        gate._set_entry(gate._widgets.macros.kcal, "100")
        gate._set_entry(gate._widgets.amount_entry, "200")
        gate._on_amount_change(None)
        assert gate._vars.preview.get()

    def test_projection_else_without_item(self, gate: MealGate) -> None:
        """With a budget but no priced item, no after-this-item is shown."""
        write_budget(2000)
        gate._refresh_projection()
        text = gate._vars.projection.get()
        assert "left" in text
        assert "after this item" not in text

    def test_keyrelease_grams_mode(self, gate: MealGate) -> None:
        """In grams mode the per-item weight is not touched on keyrelease."""
        gate._vars.unit.set("grams")
        gate._set_desc("apple")
        gate._on_desc_keyrelease(None)

    def test_keyrelease_items_unknown(self, gate: MealGate) -> None:
        """An unknown item in items mode leaves the per field unchanged."""
        gate._vars.unit.set("items")
        gate._set_desc("zzzz")
        gate._on_desc_keyrelease(None)

    def test_apply_reference_keeps_existing_amount(self, gate: MealGate) -> None:
        """A grams-mode pick does not overwrite an amount already typed."""
        gate._set_entry(gate._widgets.amount_entry, "50")
        gate._apply_reference(_nutrition(100, 100))
        assert gate._widgets.amount_entry.get() == "50"
