"""Tests for _state.py — the HMAC-signed daily food log.

State files are redirected into ``tmp_path`` and a deterministic HMAC key is
provided by the autouse conftest fixtures, so signing, verification, and the
defensive read paths are all exercised in isolation.
"""

from __future__ import annotations

import json
from unittest.mock import patch

import pytest

from diet_guard import _state, _state_sync, _state_today
from diet_guard._estimator import Nutrition
from diet_guard._state import (
    load_log,
    log_meal,
)
from diet_guard._state_sync import (
    read_raw_log,
    resign_entry,
    undo_last_today,
    write_raw_log,
)
from diet_guard._state_today import (
    logged_slots_today,
    today_entries,
    today_total_kcal,
)


def _nut(
    kcal: float, *, protein: float = 0, carbs: float = 0, fat: float = 0
) -> Nutrition:
    """Build a Nutrition for a logged meal."""
    return Nutrition(kcal, protein, carbs, fat, 100, "manual")


def _raw() -> dict[str, list[dict[str, object]]]:
    """Read the raw log file as parsed JSON (no verification)."""
    return json.loads(_state.FOOD_LOG_FILE.read_text(encoding="utf-8"))


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
        with patch.object(_state_sync, "compute_entry_hmac", return_value=None):
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
        with patch.object(_state_today, "_today", return_value="2026-06-22"):
            assert today_entries() == [resigned]

    def test_no_op_signature_wise_when_no_key_available(self) -> None:
        """Without an HMAC key, resign_entry produces no hmac field."""
        entry = log_meal("a", _nut(100), slot=8)
        with patch.object(_state_sync, "compute_entry_hmac", return_value=None):
            resigned = resign_entry(entry)
        assert "hmac" not in resigned
