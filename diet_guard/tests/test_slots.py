"""Tests for _slots.py — pure meal-slot arithmetic.

Every function is a total function of ``now`` and an explicit schedule, so the
time-of-day edges are exercised directly with fixed ``datetime`` values.  The
assertions below use ``DEFAULT_SCHEDULE`` (08/12/16/20, cutoff 22:00) so they
still pin the behaviour these functions had when those hours were hardcoded.
"""

from __future__ import annotations

from datetime import datetime, timezone

from diet_guard._meal_schedule import DEFAULT_SCHEDULE, MealSchedule
from diet_guard._slots import (
    current_slot,
    day_slots,
    elapsed_slots,
    missing_slots,
    slot_for_log,
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
        assert day_slots(DEFAULT_SCHEDULE) == (8, 12, 16, 20)


class TestEnforcementWindow:
    """The [day_start, eating_end) active window."""

    def test_before_window(self) -> None:
        """An hour before the first slot is outside the window."""
        assert not within_enforcement_window(_at(7), DEFAULT_SCHEDULE)

    def test_first_slot_is_inside(self) -> None:
        """The day-start hour is inside (inclusive lower bound)."""
        assert within_enforcement_window(_at(8), DEFAULT_SCHEDULE)

    def test_last_active_hour_inside(self) -> None:
        """21:00 is still inside; the cutoff is exclusive at 22:00."""
        assert within_enforcement_window(_at(21), DEFAULT_SCHEDULE)

    def test_cutoff_is_outside(self) -> None:
        """The cutoff hour itself is outside (exclusive upper bound)."""
        assert not within_enforcement_window(_at(22), DEFAULT_SCHEDULE)


class TestElapsedSlots:
    """Which slots have arrived as of now."""

    def test_empty_before_window(self) -> None:
        """Before the first slot, nothing has elapsed."""
        assert elapsed_slots(_at(7), DEFAULT_SCHEDULE) == ()

    def test_empty_after_cutoff(self) -> None:
        """After the overnight cutoff, slots lapse to empty."""
        assert elapsed_slots(_at(23), DEFAULT_SCHEDULE) == ()

    def test_first_slot_only(self) -> None:
        """At 08:00 exactly, only the 08:00 slot has elapsed."""
        assert elapsed_slots(_at(8), DEFAULT_SCHEDULE) == (8,)

    def test_midday(self) -> None:
        """At 13:00, the 08:00 and 12:00 slots have elapsed."""
        assert elapsed_slots(_at(13), DEFAULT_SCHEDULE) == (8, 12)

    def test_all_elapsed_late(self) -> None:
        """At 21:00, every slot for the day has elapsed."""
        assert elapsed_slots(_at(21), DEFAULT_SCHEDULE) == (8, 12, 16, 20)


class TestMissingSlots:
    """Elapsed slots not yet satisfied by a logged meal."""

    def test_none_missing_when_all_logged(self) -> None:
        """All elapsed slots logged -> nothing due."""
        assert missing_slots(_at(13), {8, 12}, DEFAULT_SCHEDULE) == ()

    def test_reports_unlogged(self) -> None:
        """Only the unlogged elapsed slots are returned, ascending."""
        assert missing_slots(_at(17), {8}, DEFAULT_SCHEDULE) == (12, 16)


class TestCurrentSlot:
    """The most recent elapsed slot (used to tag a CLI ``ate``)."""

    def test_none_before_any_slot(self) -> None:
        """Before the first slot there is no current slot."""
        assert current_slot(_at(7), DEFAULT_SCHEDULE) is None

    def test_latest_elapsed(self) -> None:
        """At 13:00 the current slot is 12:00 (the latest elapsed)."""
        assert current_slot(_at(13), DEFAULT_SCHEDULE) == 12


class TestSlotForLog:
    """Slot attribution for a logged meal, including the off-hours clamp.

    Keep in lockstep with ``slot.dart``'s ``slotForLog`` tests: a divergence
    here means the PC and the phone disagree about which checkpoint a meal
    satisfied.
    """

    def test_before_the_first_window_clamps_to_the_first_slot(self) -> None:
        """An early breakfast counts toward 08:00 rather than nothing."""
        assert slot_for_log(_at(7), DEFAULT_SCHEDULE) == 8

    def test_midnight_clamps_to_the_first_slot(self) -> None:
        """The small hours are still "before the first window"."""
        assert slot_for_log(_at(0), DEFAULT_SCHEDULE) == 8

    def test_first_slot_boundary_is_unchanged(self) -> None:
        """08:00 exactly is inside the window, so no clamp applies."""
        assert slot_for_log(_at(8), DEFAULT_SCHEDULE) == 8

    def test_inside_the_window_matches_current_slot(self) -> None:
        """Within the window attribution is just the latest elapsed slot."""
        assert (
            slot_for_log(_at(13), DEFAULT_SCHEDULE)
            == current_slot(_at(13), DEFAULT_SCHEDULE)
            == 12
        )

    def test_last_in_window_hour_is_unchanged(self) -> None:
        """21:59 is still inside the window and lands on 20:00."""
        assert slot_for_log(_at(21), DEFAULT_SCHEDULE) == 20

    def test_after_the_last_window_clamps_to_the_last_slot(self) -> None:
        """A late dinner counts toward 20:00 rather than nothing."""
        assert slot_for_log(_at(22), DEFAULT_SCHEDULE) == 20

    def test_late_evening_clamps_to_the_last_slot(self) -> None:
        """23:00 clamps the same way as the 22:00 boundary."""
        assert slot_for_log(_at(23), DEFAULT_SCHEDULE) == 20

    def test_never_returns_none(self) -> None:
        """Every hour of the day attributes to some slot."""
        assert all(
            slot_for_log(_at(hour), DEFAULT_SCHEDULE) in day_slots(DEFAULT_SCHEDULE)
            for hour in range(24)
        )

    def test_clamps_across_configured_schedules(self) -> None:
        """The clamp rule holds for any schedule, not just the default.

        Sweeps every hour against several windows.  ``slot.dart`` runs the
        identical sweep: the two must agree on every cell, because a device
        that attributes a meal to a different slot than its peer leaves the
        other device's checkpoint permanently unsatisfied.
        """
        for schedule in (
            DEFAULT_SCHEDULE,
            MealSchedule(8, 20, 5),
            MealSchedule(6, 22, 6),
            MealSchedule(0, 23, 2),
            MealSchedule(10, 14, 3),
        ):
            slots = day_slots(schedule)
            for hour in range(24):
                attributed = slot_for_log(_at(hour), schedule)
                assert attributed in slots
                if hour < slots[0]:
                    assert attributed == slots[0]
                elif hour >= schedule.enforcement_end_hour:
                    assert attributed == slots[-1]
                else:
                    # Inside the window: the most recent slot that has opened.
                    assert attributed == max(s for s in slots if s <= hour)


class TestSlotLabel:
    """Human HH:00 labels."""

    def test_morning_zero_padded(self) -> None:
        """A single-digit hour is zero-padded."""
        assert slot_label(8) == "08:00"

    def test_evening(self) -> None:
        """A two-digit hour formats plainly."""
        assert slot_label(20) == "20:00"


class TestConfiguredSchedules:
    """Slot arithmetic against schedules other than the default."""

    def test_five_meals_shifts_the_checkpoints(self) -> None:
        """The user's example schedule drives elapsed/missing correctly."""
        schedule = MealSchedule(8, 20, 5)
        assert day_slots(schedule) == (8, 11, 14, 17, 20)
        assert elapsed_slots(_at(14), schedule) == (8, 11, 14)
        assert missing_slots(_at(14), {8, 11}, schedule) == (14,)

    def test_enforcement_follows_the_last_meal(self) -> None:
        """A window ending at 18:00 stops enforcing at 20:00, not 22:00."""
        schedule = MealSchedule(8, 18, 3)
        assert within_enforcement_window(_at(19), schedule)
        assert not within_enforcement_window(_at(20), schedule)
        assert elapsed_slots(_at(20), schedule) == ()

    def test_midnight_first_slot_is_not_treated_as_absent(self) -> None:
        """Slot 0 is a real slot, not a falsy stand-in for "nothing elapsed".

        Guards the ``or`` bug this used to have in ``_gatelock._pending_slots``:
        ``current_slot(...) or day_slots()[0]`` silently swallowed slot 0.
        """
        schedule = MealSchedule(0, 12, 3)
        assert day_slots(schedule) == (0, 6, 12)
        assert current_slot(_at(0), schedule) == 0
        assert current_slot(_at(0), schedule) is not None
        assert slot_for_log(_at(0), schedule) == 0
