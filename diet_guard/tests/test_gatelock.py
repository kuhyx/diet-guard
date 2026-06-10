"""Tests for _gatelock.py — the fullscreen log-to-unlock gate window.

A functional fake ``tk`` (stateful Entry/Text/Listbox/StringVar widgets and a
real ``TclError``) replaces the conftest's blanket MagicMock for the duration of
each gate test, so the window's *logic* runs for real against in-memory widgets
without ever opening a window or grabbing the keyboard.
"""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from python_pkg.diet_guard import _gatelock
from python_pkg.diet_guard._budget import seal_budget
from python_pkg.diet_guard._estimator import Nutrition
from python_pkg.diet_guard._gatelock import (
    MealGate,
    _format_preview,
    _pending_slots,
    _safe_float,
    acquire_gate_lock,
    release_gate_lock,
    wait_for_display,
)
from python_pkg.diet_guard._meal import MealItem

# Captured before any autouse fixture patches the module attribute, so the real
# class (not the conftest MagicMock) is available for its callback-error test.
_REAL_GATE_ROOT = _gatelock._GateRoot


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
    """A functional one-line entry (delete clears, insert appends)."""

    def __init__(self, *args: object, **kwargs: object) -> None:
        self._value = ""

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
        pass

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
    """A generic no-op widget for Frame/Label/Button/OptionMenu."""

    def __init__(self, *args: object, **kwargs: object) -> None:
        pass

    def pack(self, *args: object, **kwargs: object) -> FakeWidget:
        return self

    def place(self, *args: object, **kwargs: object) -> FakeWidget:
        return self

    def configure(self, *args: object, **kwargs: object) -> FakeWidget:
        return self

    config = configure

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
    Entry=FakeEntry,
    Text=FakeText,
    Listbox=FakeListbox,
    Event=object,
)


@pytest.fixture
def gate() -> object:
    """Build a demo gate whose widgets are functional fakes."""
    with patch.object(_gatelock, "tk", _FAKE_TK):
        yield MealGate(demo_mode=True)


def _nutrition(kcal: float = 100, grams: float = 100) -> Nutrition:
    """A simple reference nutrition for driving the form."""
    return Nutrition(kcal, 10, 20, 5, grams, "food bank")


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


class TestGateRootCallback:
    """The root's callback-exception routing."""

    def test_routes_to_handler(self) -> None:
        """A set handler is invoked on a callback error."""
        root = _REAL_GATE_ROOT.__new__(_REAL_GATE_ROOT)
        root.on_callback_error = MagicMock()
        _REAL_GATE_ROOT.report_callback_exception(
            root, ValueError, ValueError("x"), None
        )
        root.on_callback_error.assert_called_once()

    def test_no_handler_is_safe(self) -> None:
        """With no handler set, the error is just logged."""
        root = _REAL_GATE_ROOT.__new__(_REAL_GATE_ROOT)
        root.on_callback_error = None
        _REAL_GATE_ROOT.report_callback_exception(
            root, ValueError, ValueError("x"), None
        )


# --------------------------------------------------------------------------
# Construction
# --------------------------------------------------------------------------


class TestConstruction:
    """Building the window in both modes."""

    def test_demo_builds(self, gate: MealGate) -> None:
        """A demo gate constructs with a pending slot and grams basis."""
        assert gate.demo_mode is True
        assert gate._unit.get() == "grams"

    def test_production_builds(self) -> None:
        """A production gate disables VT switching and grabs input."""
        with (
            patch.object(_gatelock, "tk", _FAKE_TK),
            patch.object(_gatelock.shutil, "which", return_value=None),
        ):
            gate = MealGate(demo_mode=False)
        assert gate.demo_mode is False


# --------------------------------------------------------------------------
# Form logic
# --------------------------------------------------------------------------


class TestFormBasics:
    """Field helpers and the numeric validator."""

    def test_numeric_validator(self, gate: MealGate) -> None:
        """Blank and numbers are allowed; words are not."""
        assert gate._is_numeric_or_blank("")
        assert gate._is_numeric_or_blank("12.5")
        assert not gate._is_numeric_or_blank("abc")

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
        gate._kcal_entry.insert(0, "abc")
        assert gate._macro_values() is None


class TestReferenceModel:
    """The reference -> total nutrition computation."""

    def test_reference_none_without_calories(self, gate: MealGate) -> None:
        """No calories typed means no reference yet."""
        assert gate._reference_nutrition() is None

    def test_current_is_reference_without_amount(self, gate: MealGate) -> None:
        """With calories but no amount, the reference stands in as the total."""
        gate._kcal_entry.insert(0, "200")
        current = gate._current_nutrition()
        assert current is not None
        assert current.kcal == 200

    def test_current_scales_with_amount(self, gate: MealGate) -> None:
        """Grams eaten scale the per-100 g reference into the total."""
        gate._kcal_entry.insert(0, "200")
        gate._amount_entry.insert(0, "200")
        current = gate._current_nutrition()
        assert current is not None
        assert current.kcal == 400


class TestSuggestions:
    """Autocomplete population and selection."""

    def test_keyrelease_items_mode_shows_weight(self, gate: MealGate) -> None:
        """In items mode, typing a staple fills the per-item weight."""
        gate._unit.set("items")
        gate._set_desc("apple")
        gate._on_desc_keyrelease(None)
        assert gate._per_entry.get() == "182"

    def test_select_bank_fills_name_and_macros(self, gate: MealGate) -> None:
        """Picking a banked suggestion adopts its name and macros."""
        gate._suggestions = [("apple pie", _nutrition(300, 120))]
        gate._suggestion_mode = "bank"
        gate._suggestion_box.selection_set(0)
        gate._on_suggestion_select(None)
        assert gate._get_desc() == "apple pie"
        assert gate._kcal_entry.get() == "300"

    def test_select_candidate_keeps_description(self, gate: MealGate) -> None:
        """An OFF candidate fills macros but not the typed description."""
        gate._set_desc("my dish")
        gate._suggestions = [("openfoodfacts: X", _nutrition(250, 100))]
        gate._suggestion_mode = "candidates"
        gate._suggestion_box.selection_set(0)
        gate._on_suggestion_select(None)
        assert gate._get_desc() == "my dish"

    def test_select_no_selection(self, gate: MealGate) -> None:
        """No selection is a no-op."""
        gate._on_suggestion_select(None)

    def test_select_out_of_range(self, gate: MealGate) -> None:
        """A stale selection index beyond the list is ignored."""
        gate._suggestions = []
        gate._suggestion_box.selection_set(5)
        gate._on_suggestion_select(None)


class TestUnitToggle:
    """Switching the grams/items basis."""

    def test_toggle_reconverts_picked_food(self, gate: MealGate) -> None:
        """A picked food is re-expressed per item, then back per 100 g."""
        gate._apply_reference(_nutrition(52, 100), name="apple")
        gate._unit.set("items")
        gate._on_unit_change("items")
        per_item = gate._kcal_entry.get()
        gate._unit.set("grams")
        gate._on_unit_change("grams")
        assert gate._kcal_entry.get() == "52"
        assert per_item != "52"

    def test_toggle_without_reference_clears(self, gate: MealGate) -> None:
        """With no picked food, a toggle clears the macro fields."""
        gate._kcal_entry.insert(0, "123")
        gate._last_reference = None
        gate._unit.set("items")
        gate._on_unit_change("items")
        assert gate._kcal_entry.get() == ""

    def test_macro_edit_drops_reference(self, gate: MealGate) -> None:
        """Hand-editing a macro invalidates the stored reference."""
        gate._last_reference = _nutrition()
        gate._on_macro_edit(None)
        assert gate._last_reference is None


class TestSubmit:
    """The two-step submit (look up, then log)."""

    def test_empty_description(self, gate: MealGate) -> None:
        """Submitting with no description prompts for one."""
        gate._on_submit()
        assert "Type what you ate" in gate._status.get()

    def test_non_numeric_macros(self, gate: MealGate) -> None:
        """Non-numeric macros are rejected before logging."""
        gate._set_desc("apple")
        gate._kcal_entry.insert(0, "abc")
        gate._on_submit()
        assert "must be numbers" in gate._status.get()

    def test_blank_calories_triggers_lookup(self, gate: MealGate) -> None:
        """A blank calorie field looks the food up rather than logging."""
        gate._set_desc("apple")
        with patch.object(gate, "_begin_lookup") as lookup:
            gate._on_submit()
        lookup.assert_called_once()

    def test_defensive_none_nutrition(self, gate: MealGate) -> None:
        """A calorie value but unresolvable nutrition prompts again (guard)."""
        gate._set_desc("apple")
        gate._kcal_entry.insert(0, "200")
        with patch.object(gate, "_current_nutrition", return_value=None):
            gate._on_submit()
        assert "Enter the calories" in gate._status.get()

    def test_valid_submit_records(self, gate: MealGate) -> None:
        """A described, priced meal is recorded."""
        gate._set_desc("apple")
        gate._kcal_entry.insert(0, "95")
        with patch.object(gate, "_record") as record:
            gate._on_submit()
        record.assert_called_once()

    def test_on_return_submits(self, gate: MealGate) -> None:
        """Enter in a numeric field submits."""
        with patch.object(gate, "_on_submit") as submit:
            gate._on_return(None)
        submit.assert_called_once()


class TestLookup:
    """Step one: filling the form from a lookup."""

    def test_no_candidates(self, gate: MealGate) -> None:
        """No match asks for a manual value."""
        gate._set_desc("nonsense")
        with patch.object(_gatelock, "lookup_candidates", return_value=[]):
            gate._begin_lookup("nonsense")
        assert "Couldn't look that up" in gate._status.get()

    def test_single_candidate(self, gate: MealGate) -> None:
        """A single match fills the fields and invites review."""
        with patch.object(
            _gatelock,
            "lookup_candidates",
            return_value=[("apple", _nutrition(95, 100))],
        ):
            gate._begin_lookup("apple")
        assert "Review the values" in gate._status.get()

    def test_multiple_candidates(self, gate: MealGate) -> None:
        """Several matches invite picking another."""
        with patch.object(
            _gatelock,
            "lookup_candidates",
            return_value=[
                ("a", _nutrition(95, 100)),
                ("b", _nutrition(120, 100)),
            ],
        ):
            gate._begin_lookup("apple")
        assert "pick another" in gate._status.get()


class TestRecord:
    """Logging a meal and advancing the slot walk."""

    def test_demo_logs_without_slot(self, gate: MealGate) -> None:
        """A demo record banks the food but tags no real slot."""
        gate._pending = [8]
        with patch.object(_gatelock, "log_meal") as log:
            gate._record("apple", _nutrition(95, 100))
        assert log.call_args.args[2] is None

    def test_last_slot_unlocks(self, gate: MealGate) -> None:
        """Recording the final pending slot triggers the unlock."""
        gate._pending = [8]
        with (
            patch.object(_gatelock, "log_meal"),
            patch.object(_gatelock, "remember_food"),
            patch.object(gate, "_unlock") as unlock,
        ):
            gate._record("apple", _nutrition(95, 100))
        unlock.assert_called_once()

    def test_more_slots_continue(self, gate: MealGate) -> None:
        """With slots remaining, the form clears and prompts the next."""
        gate._pending = [8, 12]
        with (
            patch.object(_gatelock, "log_meal"),
            patch.object(_gatelock, "remember_food"),
        ):
            gate._record("apple", _nutrition(95, 100))
        assert gate._pending == [12]
        assert "next meal" in gate._status.get()

    def test_unlock_schedules_close(self, gate: MealGate) -> None:
        """Unlock sets the closing status and schedules teardown."""
        gate._unlock("logged X")
        assert "unlocking" in gate._status.get()


class TestDashboard:
    """The running calorie/macro panel."""

    def test_headline_with_budget(self, gate: MealGate) -> None:
        """A sealed budget shows consumed/target/remaining."""
        seal_budget(2000)
        gate._refresh_dashboard()
        assert "left" in gate._cal_headline.get()

    def test_headline_without_budget(self, gate: MealGate) -> None:
        """With no budget, only today's total is shown."""
        gate._refresh_dashboard()
        assert "kcal today" in gate._cal_headline.get()

    def test_dashboard_lists_entries(self, gate: MealGate) -> None:
        """Logged entries appear in the detail panel."""
        seal_budget(2000, weight_kg=80)
        _gatelock.log_meal("apple", _nutrition(95, 100), 8)
        gate._refresh_dashboard()
        text = gate._dashboard.get()
        assert "apple" in text
        assert "protein" in text

    def test_dashboard_empty(self, gate: MealGate) -> None:
        """With nothing logged, the panel says so."""
        gate._refresh_dashboard()
        assert "nothing logged yet" in gate._dashboard.get()

    def test_slot_header_variants(self, gate: MealGate) -> None:
        """The header covers none / one / several pending slots."""
        gate._pending = []
        gate._refresh_slot_header()
        assert "All meals logged" in gate._slot_header.get()
        gate._pending = [8]
        gate._refresh_slot_header()
        assert "Log your" in gate._slot_header.get()
        gate._pending = [8, 12]
        gate._refresh_slot_header()
        assert "remaining" in gate._slot_header.get()

    def test_projection_with_budget(self, gate: MealGate) -> None:
        """The projection shows the after-this-item remaining when priced."""
        seal_budget(2000)
        gate._kcal_entry.insert(0, "300")
        gate._refresh_projection()
        assert "after this item" in gate._projection.get()


class TestWindowMechanics:
    """VT switching, grabbing, signals, and teardown."""

    def test_disable_vt_no_tool(self, gate: MealGate) -> None:
        """A missing setxkbmap leaves VT switching enabled."""
        with patch.object(_gatelock.shutil, "which", return_value=None):
            gate._disable_vt_switching()
        assert gate._vt_disabled is False

    def test_disable_and_restore_vt(self, gate: MealGate) -> None:
        """With the tool present, VT switching toggles off then back on."""
        with (
            patch.object(_gatelock.shutil, "which", return_value="/x/setxkbmap"),
            patch.object(_gatelock.subprocess, "run") as run,
        ):
            gate._disable_vt_switching()
            assert gate._vt_disabled is True
            gate._restore_vt_switching()
            assert gate._vt_disabled is False
        assert run.call_count == 2

    def test_restore_when_not_disabled(self, gate: MealGate) -> None:
        """Restoring when never disabled is a no-op."""
        gate._vt_disabled = False
        gate._restore_vt_switching()

    def test_grab_success(self, gate: MealGate) -> None:
        """A successful grab focuses the first field."""
        gate.root.grab_set_global = MagicMock()
        gate._acquire_global_grab(attempt=1)

    def test_grab_retries_on_conflict(self, gate: MealGate) -> None:
        """A held grab reschedules another attempt instead of giving up."""
        gate.root.grab_set_global = MagicMock(side_effect=_FakeTclError)
        gate.root.after = MagicMock()
        gate._acquire_global_grab(attempt=_gatelock._GRAB_LOG_EVERY)
        gate.root.after.assert_called_once()

    def test_focus_first_field(self, gate: MealGate) -> None:
        """Focusing the first field is safe."""
        gate._focus_first_field()

    def test_keepalive_rearms(self, gate: MealGate) -> None:
        """The keepalive reschedules itself."""
        gate.root.after = MagicMock()
        gate._keepalive()
        gate.root.after.assert_called_once()

    def test_signal_restores_and_exits(self, gate: MealGate) -> None:
        """A termination signal restores VT switching and exits."""
        with pytest.raises(SystemExit):
            gate._on_signal(15, None)

    def test_run_installs_and_loops(self, gate: MealGate) -> None:
        """run wires handlers, starts the loop, and restores on exit."""
        gate.root.mainloop = MagicMock()
        with (
            patch.object(_gatelock.signal, "signal"),
            patch.object(_gatelock.atexit, "register"),
        ):
            gate.run()
        gate.root.mainloop.assert_called_once()

    def test_close(self, gate: MealGate) -> None:
        """Close restores VT switching and destroys the window."""
        gate.root.destroy = MagicMock()
        gate.close()
        gate.root.destroy.assert_called_once()

    def test_callback_error_status(self, gate: MealGate) -> None:
        """An unexpected callback error surfaces a recoverable message."""
        gate._handle_callback_error()
        assert "went wrong" in gate._status.get()

    def test_restore_vt_without_tool(self, gate: MealGate) -> None:
        """Restoring when the tool has since vanished still clears the flag."""
        gate._vt_disabled = True
        with patch.object(_gatelock.shutil, "which", return_value=None):
            gate._restore_vt_switching()
        assert gate._vt_disabled is False

    def test_grab_retry_without_log(self, gate: MealGate) -> None:
        """An early blocked attempt reschedules without logging."""
        gate.root.grab_set_global = MagicMock(side_effect=_FakeTclError)
        gate.root.after = MagicMock()
        gate._acquire_global_grab(attempt=1)
        gate.root.after.assert_called_once()


class TestBasisAndAmount:
    """Edge branches in the grams/items basis and amount maths."""

    def test_basis_typed_value(self, gate: MealGate) -> None:
        """A typed per-value is honoured directly."""
        gate._set_entry(gate._per_entry, "50")
        assert gate._basis_grams() == 50

    def test_basis_items_known_staple(self, gate: MealGate) -> None:
        """Items mode with a blank per falls back to the staple weight."""
        gate._per_entry.delete(0)
        gate._unit.set("items")
        gate._set_desc("apple")
        assert gate._basis_grams() == 182

    def test_basis_items_unknown(self, gate: MealGate) -> None:
        """An unknown item uses the default piece weight."""
        gate._per_entry.delete(0)
        gate._unit.set("items")
        gate._set_desc("mystery")
        assert gate._basis_grams() == _gatelock.DEFAULT_ITEM_GRAMS

    def test_basis_grams_default(self, gate: MealGate) -> None:
        """Grams mode with a blank per uses the per-100 g default."""
        gate._per_entry.delete(0)
        assert gate._basis_grams() == _gatelock._DEFAULT_PER_GRAMS

    def test_eaten_grams_none(self, gate: MealGate) -> None:
        """No amount typed yields no eaten weight."""
        assert gate._eaten_grams() is None

    def test_eaten_grams_items(self, gate: MealGate) -> None:
        """Items mode multiplies the count by the per-item weight."""
        gate._unit.set("items")
        gate._set_desc("apple")
        gate._set_entry(gate._per_entry, "182")
        gate._set_entry(gate._amount_entry, "5")
        assert gate._eaten_grams() == 5 * 182

    def test_amount_change_refreshes(self, gate: MealGate) -> None:
        """Changing the amount recomputes the preview."""
        gate._set_entry(gate._kcal_entry, "100")
        gate._set_entry(gate._amount_entry, "200")
        gate._on_amount_change(None)
        assert gate._preview.get()

    def test_projection_else_without_item(self, gate: MealGate) -> None:
        """With a budget but no priced item, no after-this-item is shown."""
        seal_budget(2000)
        gate._refresh_projection()
        text = gate._projection.get()
        assert "left" in text
        assert "after this item" not in text

    def test_keyrelease_grams_mode(self, gate: MealGate) -> None:
        """In grams mode the per-item weight is not touched on keyrelease."""
        gate._unit.set("grams")
        gate._set_desc("apple")
        gate._on_desc_keyrelease(None)

    def test_keyrelease_items_unknown(self, gate: MealGate) -> None:
        """An unknown item in items mode leaves the per field unchanged."""
        gate._unit.set("items")
        gate._set_desc("zzzz")
        gate._on_desc_keyrelease(None)

    def test_apply_reference_keeps_existing_amount(self, gate: MealGate) -> None:
        """A grams-mode pick does not overwrite an amount already typed."""
        gate._set_entry(gate._amount_entry, "50")
        gate._apply_reference(_nutrition(100, 100))
        assert gate._amount_entry.get() == "50"


class TestDisplayReadiness:
    """The session-start display wait that absorbs the X auth-cookie race."""

    def test_ready_when_root_connects(self) -> None:
        """A Tk root that builds and destroys cleanly means the display is up."""
        fake_tk = SimpleNamespace(Tk=MagicMock(), TclError=_FakeTclError)
        with patch.object(_gatelock, "tk", fake_tk):
            assert _gatelock._display_is_ready() is True
        fake_tk.Tk.return_value.destroy.assert_called_once()

    def test_not_ready_on_tclerror(self) -> None:
        """A TclError from Tk() (no display / no cookie yet) means not ready."""
        fake_tk = SimpleNamespace(
            Tk=MagicMock(side_effect=_FakeTclError("no display")),
            TclError=_FakeTclError,
        )
        with patch.object(_gatelock, "tk", fake_tk):
            assert _gatelock._display_is_ready() is False

    def test_wait_returns_immediately_when_ready(self) -> None:
        """A display ready on the first probe returns at once and never sleeps."""
        sleep = MagicMock()
        with patch.object(_gatelock, "_display_is_ready", return_value=True):
            ready = wait_for_display(sleep=sleep, monotonic=MagicMock(return_value=0.0))
        assert ready is True
        sleep.assert_not_called()

    def test_wait_polls_then_succeeds(self) -> None:
        """Not-ready then ready sleeps once between probes, then unblocks."""
        sleep = MagicMock()
        monotonic = MagicMock(side_effect=[0.0, 0.0])
        with patch.object(_gatelock, "_display_is_ready", side_effect=[False, True]):
            assert wait_for_display(sleep=sleep, monotonic=monotonic) is True
        sleep.assert_called_once()

    def test_wait_times_out_and_defers(self) -> None:
        """A display still down at the deadline gives up so the next tick retries."""
        sleep = MagicMock()
        monotonic = MagicMock(side_effect=[0.0, 60.0])
        with patch.object(_gatelock, "_display_is_ready", return_value=False):
            assert wait_for_display(sleep=sleep, monotonic=monotonic) is False
        sleep.assert_not_called()


class TestMealFlow:
    """Building and logging a multi-item composite meal."""

    def test_meal_name_trimmed(self, gate: MealGate) -> None:
        """The meal name is read back trimmed."""
        gate._meal_name_entry.insert(0, "  dinner  ")
        assert gate._meal_name() == "dinner"

    def test_summary_empty_with_no_items(self, gate: MealGate) -> None:
        """With no accumulated items the running summary is blank."""
        gate._refresh_meal_summary()
        assert gate._meal_summary.get() == ""

    def test_summary_lists_items_and_total(self, gate: MealGate) -> None:
        """The summary shows the item names and the running calorie total."""
        gate._meal_items = [
            MealItem("salad", _nutrition(80, 120)),
            MealItem("chicken", _nutrition(330, 200)),
        ]
        gate._refresh_meal_summary()
        summary = gate._meal_summary.get()
        assert "salad, chicken" in summary
        assert "410 kcal" in summary

    def test_add_item_requires_description(self, gate: MealGate) -> None:
        """Adding with no description prompts for one."""
        gate._on_add_item()
        assert "Type the item first" in gate._status.get()

    def test_add_item_rejects_non_numeric(self, gate: MealGate) -> None:
        """Non-numeric macros are rejected before adding."""
        gate._set_desc("salad")
        gate._kcal_entry.insert(0, "abc")
        gate._on_add_item()
        assert "must be numbers" in gate._status.get()

    def test_add_item_blank_calories_looks_up(self, gate: MealGate) -> None:
        """A blank calorie field looks the item up rather than adding."""
        gate._set_desc("salad")
        with patch.object(gate, "_begin_lookup") as lookup:
            gate._on_add_item()
        lookup.assert_called_once()

    def test_add_item_defensive_none_nutrition(self, gate: MealGate) -> None:
        """A priced item that will not resolve prompts again (guard)."""
        gate._set_desc("salad")
        gate._kcal_entry.insert(0, "80")
        with patch.object(gate, "_current_nutrition", return_value=None):
            gate._on_add_item()
        assert "add the item" in gate._status.get()

    def test_add_item_accumulates_and_clears(self, gate: MealGate) -> None:
        """A valid item is appended, the form clears, the meal name is kept."""
        gate._meal_name_entry.insert(0, "dinner")
        gate._set_desc("salad")
        gate._kcal_entry.insert(0, "80")
        gate._on_add_item()
        assert len(gate._meal_items) == 1
        assert gate._meal_items[0].name == "salad"
        assert gate._get_desc() == ""
        assert gate._meal_name() == "dinner"
        assert "Added salad" in gate._status.get()

    def test_submit_empty_form_logs_accumulated_meal(self, gate: MealGate) -> None:
        """Submitting an empty form with items finalizes the meal."""
        gate._meal_items = [MealItem("salad", _nutrition(80, 120))]
        with patch.object(gate, "_log_meal") as log_meal_:
            gate._on_submit()
        log_meal_.assert_called_once()

    def test_submit_completes_meal_with_final_item(self, gate: MealGate) -> None:
        """A filled form plus existing items adds the form item, then logs."""
        gate._meal_items = [MealItem("salad", _nutrition(80, 120))]
        gate._set_desc("rice")
        gate._kcal_entry.insert(0, "260")
        with patch.object(gate, "_log_meal") as log_meal_:
            gate._on_submit()
        assert len(gate._meal_items) == 2
        assert gate._meal_items[1].name == "rice"
        log_meal_.assert_called_once()

    def test_log_meal_calls_remember_and_advances(self, gate: MealGate) -> None:
        """Logging a meal banks it under the typed name and advances the slot."""
        gate._pending = [8, 12]
        gate._meal_name_entry.insert(0, "dinner")
        gate._meal_items = [
            MealItem("salad", _nutrition(80, 120)),
            MealItem("chicken", _nutrition(330, 200)),
        ]
        with (
            patch.object(
                _gatelock, "remember_meal", return_value=_nutrition(410, 320)
            ) as remember,
            patch.object(_gatelock, "log_meal") as log,
        ):
            gate._log_meal()
        assert remember.call_args.args[0] == "dinner"
        assert log.call_args.args[0] == "dinner"
        assert gate._meal_items == []
        assert gate._pending == [12]

    def test_log_meal_uses_default_name(self, gate: MealGate) -> None:
        """A blank meal name falls back to the default."""
        gate._pending = [8, 12]
        gate._meal_items = [MealItem("soup", _nutrition(150, 300))]
        with (
            patch.object(
                _gatelock, "remember_meal", return_value=_nutrition(150, 300)
            ) as remember,
            patch.object(_gatelock, "log_meal"),
        ):
            gate._log_meal()
        assert remember.call_args.args[0] == _gatelock._DEFAULT_MEAL_NAME

    def test_slot_for_log_demo_is_none(self, gate: MealGate) -> None:
        """A demo gate tags logs with no real slot."""
        gate._pending = [8]
        assert gate._slot_for_log() is None

    def test_slot_for_log_production_is_slot(self, gate: MealGate) -> None:
        """A production gate tags logs with the current slot."""
        gate.demo_mode = False
        gate._pending = [12]
        assert gate._slot_for_log() == 12

    def test_clear_inputs_discards_meal(self, gate: MealGate) -> None:
        """Clearing between slots drops the in-progress meal and its name."""
        gate._meal_items = [MealItem("salad", _nutrition(80, 120))]
        gate._meal_name_entry.insert(0, "dinner")
        gate._meal_summary.set("something")
        gate._clear_inputs()
        assert gate._meal_items == []
        assert gate._meal_name() == ""
        assert gate._meal_summary.get() == ""

    def test_finish_slot_unlocks_on_last(self, gate: MealGate) -> None:
        """Finishing the final slot triggers unlock."""
        gate._pending = [20]
        with patch.object(gate, "_unlock") as unlock:
            gate._finish_slot("done")
        unlock.assert_called_once()
