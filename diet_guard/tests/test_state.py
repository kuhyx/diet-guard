"""Tests for _state.py — the HMAC-signed daily food log.

State files are redirected into ``tmp_path`` and a deterministic HMAC key is
provided by the autouse conftest fixtures, so signing, verification, and the
defensive read paths are all exercised in isolation.
"""

from __future__ import annotations

import json
from unittest.mock import patch

from diet_guard import _state
from diet_guard._estimator import Nutrition
from diet_guard._state import (
    entry_kcal,
    load_log,
    log_meal,
    now_local,
)
from diet_guard._state_today import (
    logged_slots_today,
    today_entries,
    today_total_kcal,
    today_total_macros,
)


def _nut(
    kcal: float, *, protein: float = 0, carbs: float = 0, fat: float = 0
) -> Nutrition:
    """Build a Nutrition for a logged meal."""
    return Nutrition(kcal, protein, carbs, fat, 100, "manual")


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


class TestIdAndComponents:
    """New per-entry fields the companion phone app's sync relies on."""

    def test_entry_has_id(self) -> None:
        """Every logged entry carries a UUID id."""
        entry = log_meal("toast", _nut(150), slot=8)
        assert isinstance(entry["id"], str)
        assert entry["id"]

    def test_ids_are_unique(self) -> None:
        """Two entries never collide on id."""
        first = log_meal("a", _nut(1), slot=8)
        second = log_meal("b", _nut(1), slot=12)
        assert first["id"] != second["id"]

    def test_components_omitted_by_default(self) -> None:
        """A single-food entry carries no components field."""
        entry = log_meal("toast", _nut(150), slot=8)
        assert "components" not in entry

    def test_components_carried_through(self) -> None:
        """A composite meal's component macros are stored on the entry."""
        parts = [
            {
                "name": "chicken",
                "kcal": 165.0,
                "protein_g": 31.0,
                "carbs_g": 0.0,
                "fat_g": 3.6,
                "grams": 100.0,
            }
        ]
        entry = log_meal("dinner", _nut(165), slot=20, components=parts)
        assert entry["components"] == parts
