"""Tests for _state.py — the HMAC-signed daily food log.

State files are redirected into ``tmp_path`` and a deterministic HMAC key is
provided by the autouse conftest fixtures, so signing, verification, and the
defensive read paths are all exercised in isolation.
"""

from __future__ import annotations

import json
from unittest.mock import patch

import pytest

from diet_guard import _state
from diet_guard._budget import BudgetNotInitializedError, write_budget
from diet_guard._estimator import Nutrition
from diet_guard._state import (
    consumption_band,
    entry_kcal,
    load_log,
    log_meal,
    logged_slots_today,
    now_local,
    read_raw_log,
    remaining_budget,
    resign_entry,
    today_entries,
    today_total_kcal,
    today_total_macros,
    undo_last_today,
    write_raw_log,
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
        write_budget(2000)
        log_meal("lunch", _nut(500), slot=12)
        assert remaining_budget() == 1500.0

    def test_band_on_track(self) -> None:
        """Well under the warn fraction is 'on track'."""
        write_budget(2000)
        log_meal("a", _nut(500), slot=8)
        assert consumption_band() == "on track"

    def test_band_approaching(self) -> None:
        """At or above the warn fraction but under budget is 'approaching limit'."""
        write_budget(2000)
        log_meal("a", _nut(1700), slot=8)
        assert consumption_band() == "approaching limit"

    def test_band_over(self) -> None:
        """At or above budget is 'OVER BUDGET'."""
        write_budget(2000)
        log_meal("a", _nut(2100), slot=8)
        assert consumption_band() == "OVER BUDGET"


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


class TestUndo:
    """Tombstoning the most recent entry."""

    def test_nothing_to_undo(self) -> None:
        """An empty day undoes to None."""
        assert undo_last_today() is None

    def test_undo_leaves_earlier_entries(self) -> None:
        """Undo tombstones only the last entry when others remain."""
        log_meal("a", _nut(100), slot=8)
        log_meal("b", _nut(200), slot=12)
        removed = undo_last_today()
        assert removed is not None
        assert removed["desc"] == "b"
        assert today_total_kcal() == 100.0

    def test_undo_tombstones_in_place(self) -> None:
        """Undoing the only entry keeps it on disk, marked deleted."""
        log_meal("a", _nut(100), slot=8)
        undo_last_today()
        raw = _raw()
        day = next(iter(raw))
        assert len(raw[day]) == 1
        assert raw[day][0]["deleted"] is True

    def test_undo_tombstone_excluded_from_reads(self) -> None:
        """A tombstoned entry no longer counts toward totals or slots."""
        log_meal("a", _nut(100), slot=8)
        undo_last_today()
        assert today_total_kcal() == 0.0
        assert today_entries() == []
        assert logged_slots_today() == set()

    def test_undo_re_signs_the_tombstone(self) -> None:
        """The mutated (tombstoned) entry still carries a valid signature."""
        log_meal("a", _nut(100), slot=8)
        undo_last_today()
        raw = _raw()
        day = next(iter(raw))
        assert "hmac" in raw[day][0]

    def test_undo_unsigned_when_no_key(self) -> None:
        """Re-signing a tombstone with no key available leaves it unsigned."""
        log_meal("a", _nut(100), slot=8)
        with patch.object(_state, "compute_entry_hmac", return_value=None):
            undo_last_today()
        raw = _raw()
        day = next(iter(raw))
        assert "hmac" not in raw[day][0]

    def test_undo_skips_already_tombstoned(self) -> None:
        """Undoing twice tombstones the prior entry, not the same one again."""
        log_meal("a", _nut(100), slot=8)
        log_meal("b", _nut(200), slot=12)
        undo_last_today()
        second = undo_last_today()
        assert second is not None
        assert second["desc"] == "a"

    def test_undo_nothing_left_once_all_tombstoned(self) -> None:
        """Once every entry today is tombstoned, undo returns None."""
        log_meal("a", _nut(100), slot=8)
        undo_last_today()
        assert undo_last_today() is None


class TestLoadLogSkipsTombstones:
    """``load_log`` filters out deleted entries the same way as invalid ones."""

    def test_day_with_only_a_tombstone_is_omitted(self) -> None:
        """A day whose sole entry is tombstoned is dropped entirely."""
        log_meal("a", _nut(100), slot=8)
        undo_last_today()
        assert load_log() == {}


class TestRawLogAccess:
    """Public raw read/write, used by the sync orchestration."""

    def test_read_raw_log_includes_tombstones(self) -> None:
        """Unlike load_log, read_raw_log keeps a tombstoned entry."""
        log_meal("a", _nut(100), slot=8)
        undo_last_today()
        raw = read_raw_log()
        day = next(iter(raw))
        assert raw[day][0]["deleted"] is True

    def test_write_raw_log_roundtrips(self) -> None:
        """write_raw_log persists exactly what read_raw_log later returns."""
        log = {"2026-06-22": [{"id": "x", "time": "2026-06-22T08:00:00+02:00"}]}
        write_raw_log(log)
        assert read_raw_log() == log

    def test_write_leaves_no_temp_file(self) -> None:
        """A successful atomic write cleans up its temp file."""
        write_raw_log({"2026-06-22": [{"id": "x"}]})
        assert list(_state.FOOD_LOG_FILE.parent.glob("*.tmp")) == []

    def test_write_failure_preserves_prior_log(self) -> None:
        """A failed replace leaves the old log intact and no temp behind.

        This is the point of the atomic write: a concurrent reader (the gate
        now syncs while the timer may also write) never sees a torn or empty
        log just because a write was interrupted.
        """
        write_raw_log({"2026-06-22": [{"id": "original"}]})
        with (
            patch("pathlib.Path.replace", side_effect=OSError("no space")),
            pytest.raises(OSError, match="no space"),
        ):
            write_raw_log({"2026-06-22": [{"id": "clobbered"}]})
        assert read_raw_log() == {"2026-06-22": [{"id": "original"}]}
        assert list(_state.FOOD_LOG_FILE.parent.glob("*.tmp")) == []


class TestResignEntry:
    """resign_entry recomputes the hmac so a merged entry validates again."""

    def test_strips_and_recomputes_signature(self) -> None:
        """A re-signed entry's hmac changes but verifies against the key."""
        entry = log_meal("a", _nut(100), slot=8)
        tampered = dict(entry, kcal=999.0)
        resigned = resign_entry(tampered)
        assert resigned["hmac"] != entry["hmac"]
        write_raw_log({"2026-06-22": [resigned]})
        with patch.object(_state, "_today", return_value="2026-06-22"):
            assert today_entries() == [resigned]

    def test_no_op_signature_wise_when_no_key_available(self) -> None:
        """Without an HMAC key, resign_entry produces no hmac field."""
        entry = log_meal("a", _nut(100), slot=8)
        with patch.object(_state, "compute_entry_hmac", return_value=None):
            resigned = resign_entry(entry)
        assert "hmac" not in resigned
