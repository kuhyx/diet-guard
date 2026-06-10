"""Tests for _slots.py — pure meal-slot arithmetic.

Every function is a total function of ``now`` and the slot constants, so the
time-of-day edges are exercised directly with fixed ``datetime`` values.
"""

from __future__ import annotations

from datetime import datetime, timezone

from python_pkg.diet_guard._slots import (
    current_slot,
    day_slots,
    elapsed_slots,
    missing_slots,
    slot_label,
    within_enforcement_window,
)


def _at(hour: int) -> datetime:
    """Return a fixed local datetime at ``hour`` (date is irrelevant here)."""
    return datetime(2026, 1, 1, hour, 0, tzinfo=timezone.utc)


class TestDaySlots:
    """The fixed slot schedule derived from the constants."""

    def test_default_schedule(self) -> None:
        """Slots open every 4h from 08:00 up to (not past) the 22:00 cutoff."""
        assert day_slots() == (8, 12, 16, 20)


class TestEnforcementWindow:
    """The [day_start, eating_end) active window."""

    def test_before_window(self) -> None:
        """An hour before the first slot is outside the window."""
        assert not within_enforcement_window(_at(7))

    def test_first_slot_is_inside(self) -> None:
        """The day-start hour is inside (inclusive lower bound)."""
        assert within_enforcement_window(_at(8))

    def test_last_active_hour_inside(self) -> None:
        """21:00 is still inside; the cutoff is exclusive at 22:00."""
        assert within_enforcement_window(_at(21))

    def test_cutoff_is_outside(self) -> None:
        """The cutoff hour itself is outside (exclusive upper bound)."""
        assert not within_enforcement_window(_at(22))


class TestElapsedSlots:
    """Which slots have arrived as of now."""

    def test_empty_before_window(self) -> None:
        """Before the first slot, nothing has elapsed."""
        assert elapsed_slots(_at(7)) == ()

    def test_empty_after_cutoff(self) -> None:
        """After the overnight cutoff, slots lapse to empty."""
        assert elapsed_slots(_at(23)) == ()

    def test_first_slot_only(self) -> None:
        """At 08:00 exactly, only the 08:00 slot has elapsed."""
        assert elapsed_slots(_at(8)) == (8,)

    def test_midday(self) -> None:
        """At 13:00, the 08:00 and 12:00 slots have elapsed."""
        assert elapsed_slots(_at(13)) == (8, 12)

    def test_all_elapsed_late(self) -> None:
        """At 21:00, every slot for the day has elapsed."""
        assert elapsed_slots(_at(21)) == (8, 12, 16, 20)


class TestMissingSlots:
    """Elapsed slots not yet satisfied by a logged meal."""

    def test_none_missing_when_all_logged(self) -> None:
        """All elapsed slots logged -> nothing due."""
        assert missing_slots(_at(13), {8, 12}) == ()

    def test_reports_unlogged(self) -> None:
        """Only the unlogged elapsed slots are returned, ascending."""
        assert missing_slots(_at(17), {8}) == (12, 16)


class TestCurrentSlot:
    """The most recent elapsed slot (used to tag a CLI ``ate``)."""

    def test_none_before_any_slot(self) -> None:
        """Before the first slot there is no current slot."""
        assert current_slot(_at(7)) is None

    def test_latest_elapsed(self) -> None:
        """At 13:00 the current slot is 12:00 (the latest elapsed)."""
        assert current_slot(_at(13)) == 12


class TestSlotLabel:
    """Human HH:00 labels."""

    def test_morning_zero_padded(self) -> None:
        """A single-digit hour is zero-padded."""
        assert slot_label(8) == "08:00"

    def test_evening(self) -> None:
        """A two-digit hour formats plainly."""
        assert slot_label(20) == "20:00"
