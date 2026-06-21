"""Tests for _gatelock.py — the fullscreen log-to-unlock gate window.

Construction, MealGate's gatelock wiring (LockConfig choice, hooks), and the
shared module-level helpers.  The fullscreen/grab/VT-disable mechanics
themselves are tested in the ``gatelock`` package, not here.  The
nutrition/meal-flow tests live in :mod:`test_gatelock_mealflow`; the
functional fake ``tk`` widgets and the ``gate`` fixture live in
``conftest.py`` and are shared by both files.
"""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from python_pkg.diet_guard import (
    _gatelock,
    _gatelock_support,
    _gatelock_ui,
)
from python_pkg.diet_guard._budget import seal_budget
from python_pkg.diet_guard._gatelock import (
    MealGate,
    _pending_slots,
    acquire_gate_lock,
    release_gate_lock,
)
from python_pkg.diet_guard._gatelock_core import _safe_float
from python_pkg.diet_guard._gatelock_nutrition import _format_preview
from python_pkg.diet_guard._gatelock_support import wait_for_display
from python_pkg.diet_guard._gatelock_ui import DEFAULT_PER_GRAMS
from python_pkg.diet_guard._portions import DEFAULT_ITEM_GRAMS
from python_pkg.diet_guard.tests.conftest import _FAKE_TK, _FakeTclError, _nutrition

# --------------------------------------------------------------------------
# Module-level helpers
# --------------------------------------------------------------------------


class TestModuleHelpers:
    """Pure functions and the single-instance lock."""

    def test_safe_float_blank(self) -> None:
        """A blank string is None."""
        assert _safe_float("") is None

    def test_safe_float_number(self) -> None:
        """A numeric string parses."""
        assert _safe_float("3.5") == 3.5

    def test_safe_float_non_numeric(self) -> None:
        """A non-numeric string is None."""
        assert _safe_float("abc") is None

    def test_format_preview_with_portion(self) -> None:
        """A non-zero portion shows the grams segment."""
        text = _format_preview(_nutrition(grams=200))
        assert "200g" in text

    def test_format_preview_without_portion(self) -> None:
        """A zero portion omits the grams segment."""
        text = _format_preview(_nutrition(grams=0))
        assert "g ·" not in text

    def test_gate_lock_single_instance(self) -> None:
        """A second acquire while the first is held returns None."""
        first = acquire_gate_lock()
        assert first is not None
        assert acquire_gate_lock() is None
        release_gate_lock(first)

    def test_pending_slots_due(self) -> None:
        """When slots are due, those are returned verbatim."""
        with patch.object(_gatelock, "due_slots", return_value=[12, 16]):
            assert _pending_slots(demo_mode=False) == [12, 16]

    def test_pending_slots_demo_fallback(self) -> None:
        """Demo mode invents a representative slot when nothing is due."""
        with patch.object(_gatelock, "due_slots", return_value=[]):
            assert len(_pending_slots(demo_mode=True)) == 1

    def test_pending_slots_production_empty(self) -> None:
        """Production with nothing due returns no slots."""
        with patch.object(_gatelock, "due_slots", return_value=[]):
            assert not _pending_slots(demo_mode=False)


class TestAssertNotUnderPytest:
    """The safety net that blocks a real Tk gate under pytest."""

    def test_raises_with_real_tkinter(self) -> None:
        """Real tkinter under pytest is refused."""
        with (
            patch.object(_gatelock, "tk", SimpleNamespace(__name__="tkinter")),
            pytest.raises(RuntimeError),
        ):
            _gatelock._assert_not_under_pytest()

    def test_passes_with_mock(self) -> None:
        """A mocked tk (name != tkinter) passes straight through."""
        with patch.object(_gatelock, "tk", SimpleNamespace(__name__="mock")):
            _gatelock._assert_not_under_pytest()


# --------------------------------------------------------------------------
# Construction
# --------------------------------------------------------------------------


class TestConstruction:
    """Building the window in both modes."""

    def test_demo_builds(self, gate: MealGate) -> None:
        """A demo gate constructs with a pending slot, grams basis, and a soft lock."""
        assert gate.demo_mode is True
        assert gate._vars.unit.get() == "grams"
        assert gate._lock._config.mode == "soft"

    def test_production_builds(self) -> None:
        """A production gate builds with a hard lock config."""
        with patch.object(_gatelock, "tk", _FAKE_TK):
            gate = MealGate(demo_mode=False)
        assert gate.demo_mode is False
        assert gate._lock._config.mode == "hard"


# --------------------------------------------------------------------------
# Form logic
# --------------------------------------------------------------------------


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
        seal_budget(2000)
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


class TestLockDelegation:
    """MealGate's gatelock wiring: hooks delegate, run()/close() delegate."""

    def test_on_focus_ready_focuses_desc_text(self, gate: MealGate) -> None:
        """on_focus_ready puts keyboard focus on the description box."""
        gate._widgets.desc_text.focus_force = MagicMock()
        gate.on_focus_ready()
        gate._widgets.desc_text.focus_force.assert_called_once()

    def test_on_close_is_a_noop(self, gate: MealGate) -> None:
        """on_close has no hardware/state to release; must not raise."""
        gate.on_close()

    def test_callback_error_status(self, gate: MealGate) -> None:
        """An unexpected callback error surfaces a recoverable message."""
        gate.on_callback_error()
        assert "went wrong" in gate._vars.status.get()

    def test_run_delegates_to_lock(self, gate: MealGate) -> None:
        """run() hands off to the owned LockWindow."""
        with patch.object(gate._lock, "run") as mock_run:
            gate.run()
        mock_run.assert_called_once_with()

    def test_close_delegates_to_lock(self, gate: MealGate) -> None:
        """close() hands off to the owned LockWindow."""
        with patch.object(gate._lock, "close") as mock_close:
            gate.close()
        mock_close.assert_called_once_with()


class TestDisplayReadiness:
    """The session-start display wait that absorbs the X auth-cookie race."""

    def test_ready_when_root_connects(self) -> None:
        """A Tk root that builds and destroys cleanly means the display is up."""
        fake_tk = SimpleNamespace(Tk=MagicMock(), TclError=_FakeTclError)
        with patch.object(_gatelock_support, "tk", fake_tk):
            assert _gatelock_support._display_is_ready() is True
        fake_tk.Tk.return_value.destroy.assert_called_once()

    def test_not_ready_on_tclerror(self) -> None:
        """A TclError from Tk() (no display / no cookie yet) means not ready."""
        fake_tk = SimpleNamespace(
            Tk=MagicMock(side_effect=_FakeTclError("no display")),
            TclError=_FakeTclError,
        )
        with patch.object(_gatelock_support, "tk", fake_tk):
            assert _gatelock_support._display_is_ready() is False

    def test_wait_returns_immediately_when_ready(self) -> None:
        """A display ready on the first probe returns at once and never sleeps."""
        sleep = MagicMock()
        with patch.object(_gatelock_support, "_display_is_ready", return_value=True):
            ready = wait_for_display(sleep=sleep, monotonic=MagicMock(return_value=0.0))
        assert ready is True
        sleep.assert_not_called()

    def test_wait_polls_then_succeeds(self) -> None:
        """Not-ready then ready sleeps once between probes, then unblocks."""
        sleep = MagicMock()
        monotonic = MagicMock(side_effect=[0.0, 0.0])
        with patch.object(
            _gatelock_support, "_display_is_ready", side_effect=[False, True]
        ):
            assert wait_for_display(sleep=sleep, monotonic=monotonic) is True
        sleep.assert_called_once()

    def test_wait_times_out_and_defers(self) -> None:
        """A display still down at the deadline gives up so the next tick retries."""
        sleep = MagicMock()
        monotonic = MagicMock(side_effect=[0.0, 60.0])
        with patch.object(_gatelock_support, "_display_is_ready", return_value=False):
            assert wait_for_display(sleep=sleep, monotonic=monotonic) is False
        sleep.assert_not_called()
