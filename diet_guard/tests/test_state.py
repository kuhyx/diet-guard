"""Tests for _state.py — the HMAC-signed daily food log.

State files are redirected into ``tmp_path`` and a deterministic HMAC key is
provided by the autouse conftest fixtures, so signing, verification, and the
defensive read paths are all exercised in isolation.
"""

from __future__ import annotations

import json
from unittest.mock import patch

import pytest

from python_pkg.diet_guard import _state
from python_pkg.diet_guard._budget import BudgetNotInitializedError, seal_budget
from python_pkg.diet_guard._estimator import Nutrition
from python_pkg.diet_guard._state import (
    consumption_band,
    entry_kcal,
    load_log,
    log_meal,
    logged_slots_today,
    now_local,
    remaining_budget,
    today_entries,
    today_total_kcal,
    today_total_macros,
    undo_last_today,
)


def _nut(
    kcal: float, *, protein: float = 0, carbs: float = 0, fat: float = 0
) -> Nutrition:
    """Build a Nutrition for a logged meal."""
    return Nutrition(kcal, protein, carbs, fat, 100, "manual")


def _raw() -> dict[str, list[dict[str, object]]]:
    """Read the raw log file as parsed JSON (no verification)."""
    return json.loads(_state.FOOD_LOG_FILE.read_text(encoding="utf-8"))


class TestClock:
    """Time helpers."""

    def test_now_local_is_aware(self) -> None:
        """now_local returns a timezone-aware datetime."""
        assert now_local().tzinfo is not None


class TestEntryFloat:
    """Numeric field coercion."""

    def test_missing_is_zero(self) -> None:
        """An absent field reads as 0.0."""
        assert entry_kcal({}) == 0.0

    def test_bool_is_zero(self) -> None:
        """A bool calorie value is rejected as 0.0."""
        assert _state._entry_float({"kcal": True}, "kcal") == 0.0

    def test_number_passes(self) -> None:
        """A real number is returned as a float."""
        assert entry_kcal({"kcal": 321}) == 321.0

    def test_non_numeric_is_zero(self) -> None:
        """A non-numeric field reads as 0.0."""
        assert _state._entry_float({"kcal": "lots"}, "kcal") == 0.0


class TestLogAndTotals:
    """Logging meals and aggregating the day."""

    def test_log_and_total(self) -> None:
        """A logged meal counts toward the day's calories."""
        log_meal("toast", _nut(150), slot=8)
        assert today_total_kcal() == 150.0

    def test_entry_carries_signature(self) -> None:
        """With a key present, the stored entry is signed."""
        entry = log_meal("toast", _nut(150), slot=8)
        assert "hmac" in entry

    def test_unsigned_when_no_key(self) -> None:
        """With no key, the entry is written unsigned and still read back."""
        with patch.object(_state, "compute_entry_hmac", return_value=None):
            log_meal("toast", _nut(150), slot=8)
            assert "hmac" not in _raw()[next(iter(_raw()))][0]
            assert today_total_kcal() == 150.0

    def test_macros_sum(self) -> None:
        """today_total_macros sums protein/carbs/fat across entries."""
        log_meal("eggs", _nut(140, protein=12, carbs=1, fat=10), slot=8)
        log_meal("rice", _nut(200, protein=4, carbs=44, fat=1), slot=12)
        assert today_total_macros() == (16.0, 45.0, 11.0)

    def test_slotless_entry_counts_calories_only(self) -> None:
        """An entry logged with no slot adds calories but satisfies no slot."""
        log_meal("snack", _nut(99))
        assert today_total_kcal() == 99.0
        assert logged_slots_today() == set()


class TestLoggedSlots:
    """Which slots today's log has satisfied."""

    def test_int_slots_counted(self) -> None:
        """Integer slot tags are reported."""
        log_meal("a", _nut(1), slot=8)
        log_meal("b", _nut(1), slot=12)
        assert logged_slots_today() == {8, 12}

    def test_bool_slot_excluded(self) -> None:
        """A bool masquerading as a slot is ignored."""
        log_meal("a", _nut(1), slot=8)
        raw = _raw()
        day = next(iter(raw))
        raw[day].append({"kcal": 1, "slot": True})
        _state.FOOD_LOG_FILE.write_text(json.dumps(raw), encoding="utf-8")
        assert logged_slots_today() == {8}


class TestReadDefensive:
    """The raw read tolerates missing/corrupt/mis-shaped files."""

    def test_missing_file(self) -> None:
        """No file -> empty log."""
        assert _state._read_raw_log() == {}

    def test_corrupt_json(self) -> None:
        """Unparsable content -> empty log."""
        _state.FOOD_LOG_FILE.write_text("nope", encoding="utf-8")
        assert _state._read_raw_log() == {}

    def test_top_level_not_dict(self) -> None:
        """A non-object top level -> empty log."""
        _state.FOOD_LOG_FILE.write_text("[1,2]", encoding="utf-8")
        assert _state._read_raw_log() == {}

    def test_filters_non_list_and_non_dict(self) -> None:
        """Non-list day values are dropped; non-dict entries are filtered out."""
        _state.FOOD_LOG_FILE.write_text(
            json.dumps({"2026-06-08": [{"kcal": 1}, 99], "junk": "notalist"}),
            encoding="utf-8",
        )
        result = _state._read_raw_log()
        assert result == {"2026-06-08": [{"kcal": 1}]}


class TestVerification:
    """Tamper detection on read via the shared HMAC key."""

    def test_valid_entry_kept(self) -> None:
        """A correctly signed entry survives verification."""
        log_meal("toast", _nut(150), slot=8)
        assert today_entries()

    def test_tampered_entry_dropped(self) -> None:
        """An edited calorie value invalidates the signature and is dropped."""
        log_meal("toast", _nut(150), slot=8)
        raw = _raw()
        day = next(iter(raw))
        raw[day][0]["kcal"] = 999
        _state.FOOD_LOG_FILE.write_text(json.dumps(raw), encoding="utf-8")
        assert today_entries() == []

    def test_unsigned_rejected_when_key_present(self) -> None:
        """An entry with no signature is rejected while a key exists."""
        _state.FOOD_LOG_FILE.write_text(
            json.dumps({_state._today(): [{"kcal": 1}]}),
            encoding="utf-8",
        )
        assert today_entries() == []

    def test_unsigned_accepted_when_no_key(self) -> None:
        """With no key at all, an unsigned entry is tolerated."""
        _state.FOOD_LOG_FILE.write_text(
            json.dumps({_state._today(): [{"kcal": 5}]}),
            encoding="utf-8",
        )
        with patch.object(_state, "compute_entry_hmac", return_value=None):
            assert len(today_entries()) == 1

    def test_load_log_drops_emptied_days(self) -> None:
        """A day whose every entry is invalid is omitted entirely."""
        _state.FOOD_LOG_FILE.write_text(
            json.dumps({_state._today(): [{"kcal": 1}]}),
            encoding="utf-8",
        )
        assert load_log() == {}


class TestBudgetViews:
    """Remaining budget and the qualitative band."""

    def test_remaining_requires_budget(self) -> None:
        """With no budget sealed, remaining_budget raises."""
        with pytest.raises(BudgetNotInitializedError):
            remaining_budget()

    def test_remaining_value(self) -> None:
        """Remaining is budget minus today's total."""
        seal_budget(2000)
        log_meal("lunch", _nut(500), slot=12)
        assert remaining_budget() == 1500.0

    def test_band_on_track(self) -> None:
        """Well under the warn fraction is 'on track'."""
        seal_budget(2000)
        log_meal("a", _nut(500), slot=8)
        assert consumption_band() == "on track"

    def test_band_approaching(self) -> None:
        """At or above the warn fraction but under budget is 'approaching limit'."""
        seal_budget(2000)
        log_meal("a", _nut(1700), slot=8)
        assert consumption_band() == "approaching limit"

    def test_band_over(self) -> None:
        """At or above budget is 'OVER BUDGET'."""
        seal_budget(2000)
        log_meal("a", _nut(2100), slot=8)
        assert consumption_band() == "OVER BUDGET"


class TestUndo:
    """Removing the most recent entry."""

    def test_nothing_to_undo(self) -> None:
        """An empty day undoes to None."""
        assert undo_last_today() is None

    def test_undo_leaves_earlier_entries(self) -> None:
        """Undo removes only the last entry when others remain."""
        log_meal("a", _nut(100), slot=8)
        log_meal("b", _nut(200), slot=12)
        removed = undo_last_today()
        assert removed is not None
        assert removed["desc"] == "b"
        assert today_total_kcal() == 100.0

    def test_undo_last_entry_clears_day(self) -> None:
        """Undoing the only entry removes the day from the log."""
        log_meal("a", _nut(100), slot=8)
        undo_last_today()
        assert _state._read_raw_log() == {}
