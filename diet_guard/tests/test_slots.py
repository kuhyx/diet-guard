"""Tests for _slots.py — pure meal-slot arithmetic, in minutes of day.

Every function is a total function of ``now`` and an explicit schedule, so the
time-of-day edges are exercised directly with fixed ``datetime`` values.  The
assertions below use ``DEFAULT_SCHEDULE`` (08/12/16/20, cutoff 22:00) so they
still pin the behaviour these functions had when those hours were hardcoded.
The exhaustive cross-language edges live in the shared fixture
(``test_meal_schedule_vectors.py``); nearest/satisfied in
``test_slots_nearest.py``.
"""

from __future__ import annotations

from datetime import UTC, datetime

from diet_guard._meal_schedule import DEFAULT_SCHEDULE, MealSchedule
from diet_guard._slots import (
    current_slot,
    day_slots,
    elapsed_slots,
    minute_of_day,
    missing_slots,
    slot_for_log,
    slot_label,
    within_enforcement_window,
)


def _at(hour: int, minute: int = 0) -> datetime:
    """Return a fixed local datetime at ``hour:minute`` (date is irrelevant)."""
    return datetime(2026, 1, 1, hour, minute, tzinfo=UTC)


class TestMinuteOfDay:
    """The clock reading every other function compares against."""

    def test_counts_minutes_and_ignores_seconds(self) -> None:
        """07:15:59 is minute 435."""
        assert minute_of_day(datetime(2026, 1, 1, 7, 15, 59, tzinfo=UTC)) == 435

    def test_day_ends(self) -> None:
        """Midnight is 0 and 23:59 is 1439."""
        assert minute_of_day(_at(0)) == 0
        assert minute_of_day(_at(23, 59)) == 1439


class TestDaySlots:
    """The slot schedule derived from a schedule."""

    def test_default_schedule(self) -> None:
        """Slots open every 4h from 08:00 up to (not past) the 22:00 cutoff."""
        assert day_slots(DEFAULT_SCHEDULE) == (480, 720, 960, 1200)


class TestEnforcementWindow:
    """The [first slot, enforcement end) active window, to the minute."""

    def test_before_window(self) -> None:
        """07:59 is outside the window."""
        assert not within_enforcement_window(_at(7, 59), DEFAULT_SCHEDULE)

    def test_first_slot_is_inside(self) -> None:
        """08:00 is inside (inclusive lower bound)."""
        assert within_enforcement_window(_at(8), DEFAULT_SCHEDULE)

    def test_last_active_minute_inside(self) -> None:
        """21:59 is still inside; the cutoff is exclusive at 22:00."""
        assert within_enforcement_window(_at(21, 59), DEFAULT_SCHEDULE)

    def test_cutoff_is_outside(self) -> None:
        """22:00 itself is outside (exclusive upper bound)."""
        assert not within_enforcement_window(_at(22), DEFAULT_SCHEDULE)

    def test_quarter_hour_first_slot(self) -> None:
        """A 07:15 breakfast opens the window at 07:15, not 07:00."""
        schedule = MealSchedule(435, 1140, 5)
        assert not within_enforcement_window(_at(7, 14), schedule)
        assert within_enforcement_window(_at(7, 15), schedule)


class TestElapsedSlots:
    """Which slots have arrived as of now."""

    def test_empty_before_window(self) -> None:
        """Before the first slot, nothing has elapsed."""
        assert elapsed_slots(_at(7, 59), DEFAULT_SCHEDULE) == ()

    def test_empty_after_cutoff(self) -> None:
        """After the overnight cutoff, slots lapse to empty."""
        assert elapsed_slots(_at(23), DEFAULT_SCHEDULE) == ()

    def test_first_slot_only(self) -> None:
        """At 08:00 exactly, only the 08:00 slot has elapsed."""
        assert elapsed_slots(_at(8), DEFAULT_SCHEDULE) == (480,)

    def test_midday(self) -> None:
        """At 13:00, the 08:00 and 12:00 slots have elapsed."""
        assert elapsed_slots(_at(13), DEFAULT_SCHEDULE) == (480, 720)

    def test_all_elapsed_late(self) -> None:
        """At 21:00, every slot for the day has elapsed."""
        assert elapsed_slots(_at(21), DEFAULT_SCHEDULE) == (480, 720, 960, 1200)

    def test_a_slot_opens_on_its_minute(self) -> None:
        """10:14 has not reached a 10:15 slot; 10:15 has."""
        schedule = MealSchedule(435, 1140, 5)
        assert elapsed_slots(_at(10, 14), schedule) == (435,)
        assert elapsed_slots(_at(10, 15), schedule) == (435, 615)


class TestMissingSlots:
    """Elapsed slots not yet satisfied by a logged meal."""

    def test_none_missing_when_all_logged(self) -> None:
        """All elapsed slots logged -> nothing due."""
        assert missing_slots(_at(13), {480, 720}, DEFAULT_SCHEDULE) == ()

    def test_reports_unlogged(self) -> None:
        """Only the unlogged elapsed slots are returned, ascending."""
        assert missing_slots(_at(17), {480}, DEFAULT_SCHEDULE) == (720, 960)


class TestCurrentSlot:
    """The most recent elapsed slot (used to tag a CLI ``ate``)."""

    def test_none_before_any_slot(self) -> None:
        """Before the first slot there is no current slot."""
        assert current_slot(_at(7), DEFAULT_SCHEDULE) is None

    def test_latest_elapsed(self) -> None:
        """At 13:00 the current slot is 12:00 (the latest elapsed)."""
        assert current_slot(_at(13), DEFAULT_SCHEDULE) == 720


class TestSlotForLog:
    """Slot attribution for a logged meal, including the off-hours clamp.

    Keep in lockstep with ``slot.dart``'s ``slotForLog`` tests: a divergence
    here means the PC and the phone disagree about which checkpoint a meal
    satisfied.
    """

    def test_before_the_first_window_clamps_to_the_first_slot(self) -> None:
        """An early breakfast counts toward 08:00 rather than nothing."""
        assert slot_for_log(_at(7, 59), DEFAULT_SCHEDULE) == 480

    def test_midnight_clamps_to_the_first_slot(self) -> None:
        """The small hours are still "before the first window"."""
        assert slot_for_log(_at(0), DEFAULT_SCHEDULE) == 480

    def test_inside_the_window_matches_current_slot(self) -> None:
        """Within the window attribution is just the latest elapsed slot."""
        assert slot_for_log(_at(13), DEFAULT_SCHEDULE) == 720

    def test_last_in_window_minute_is_unchanged(self) -> None:
        """21:59 is still inside the window and lands on 20:00."""
        assert slot_for_log(_at(21, 59), DEFAULT_SCHEDULE) == 1200

    def test_after_the_last_window_clamps_to_the_last_slot(self) -> None:
        """A late dinner counts toward 20:00 rather than nothing."""
        assert slot_for_log(_at(22), DEFAULT_SCHEDULE) == 1200

    def test_clamps_across_configured_schedules(self) -> None:
        """The clamp rule holds at every minute for several windows.

        ``slot_test.dart`` runs the identical sweep: a device that attributes
        a meal to a different slot than its peer leaves the other device's
        checkpoint permanently unsatisfied.
        """
        for schedule in (
            DEFAULT_SCHEDULE,
            MealSchedule(480, 1200, 5),
            MealSchedule(435, 1140, 5),
            MealSchedule(443, 1181, 4),
            MealSchedule(0, 1439, 2),
            MealSchedule(600, 840, 3),
        ):
            slots = day_slots(schedule)
            for minute in range(1440):
                attributed = slot_for_log(_at(minute // 60, minute % 60), schedule)
                if minute < slots[0]:
                    assert attributed == slots[0]
                elif minute >= schedule.enforcement_end_minute:
                    assert attributed == slots[-1]
                else:
                    assert attributed == max(s for s in slots if s <= minute)


class TestSlotLabel:
    """Human HH:MM labels."""

    def test_zero_padded(self) -> None:
        """Hours and minutes are both zero-padded."""
        assert slot_label(435) == "07:15"
        assert slot_label(5) == "00:05"

    def test_evening(self) -> None:
        """A two-digit hour formats plainly."""
        assert slot_label(1200) == "20:00"

    def test_wraps_into_the_day(self) -> None:
        """Out-of-day values wrap, as the hour label used to with ``% 24``."""
        assert slot_label(1440) == "00:00"
        assert slot_label(-15) == "23:45"


class TestConfiguredSchedules:
    """Slot arithmetic against schedules other than the default."""

    def test_midnight_first_slot_is_not_treated_as_absent(self) -> None:
        """Slot 0 is a real slot, not a falsy stand-in for "nothing elapsed".

        Guards the ``or`` bug this used to have in ``_gatelock._pending_slots``:
        ``current_slot(...) or day_slots()[0]`` silently swallowed slot 0.
        """
        schedule = MealSchedule(0, 720, 3)
        assert day_slots(schedule) == (0, 360, 720)
        assert current_slot(_at(0), schedule) == 0
        assert slot_for_log(_at(0), schedule) == 0
