"""Tests for the pure meal-schedule derivation.

The cross-language exact values live in the shared fixture
``tests/fixtures/meal_schedule_vectors.json`` and are asserted by
``test_meal_schedule_vectors.py`` (and by its Dart mirror).  This file holds
the properties: the grid sweep, the hour-formula regression and the clamps a
human should be able to read without opening the fixture.  The sweep is
duplicated loop-for-loop in ``app/test/models/meal_schedule_test.dart``.
"""

from __future__ import annotations

from itertools import pairwise

import pytest

from diet_guard._meal_schedule import (
    DEFAULT_SCHEDULE,
    MAX_MEAL_COUNT,
    MIN_MEAL_COUNT,
    MINUTES_PER_DAY,
    SLOT_GRID_MINUTES,
    MealSchedule,
    schedule_from_wire,
    schedule_to_wire,
)

_H = 60


def _old_hour_slots(first: int, last: int, count: int) -> tuple[int, ...]:
    """Return the pre-minute whole-hour derivation, converted to minutes."""
    span, divisions = last - first, count - 1
    return tuple(
        (first + (index * span + divisions // 2) // divisions) * _H
        for index in range(count)
    )


class TestSlots:
    """Slot derivation from a schedule."""

    def test_default_is_the_historical_schedule(self) -> None:
        """The default reproduces the hours that used to be hardcoded."""
        assert DEFAULT_SCHEDULE.slots() == (480, 720, 960, 1200)

    @pytest.mark.parametrize(
        ("first", "last", "count"), [(8, 20, 4), (8, 20, 5), (7, 19, 5)]
    )
    def test_whole_hour_schedules_match_the_old_hour_formula(
        self, first: int, last: int, count: int
    ) -> None:
        """Evenly dividing hour schedules derive exactly what they used to.

        Upgrading must not move a checkpoint for the schedules people actually
        have, or every existing hour-tagged entry would satisfy a neighbour.
        """
        schedule = MealSchedule(first * _H, last * _H, count)
        assert schedule.slots() == _old_hour_slots(first, last, count)

    def test_off_grid_endpoints_are_exact(self) -> None:
        """07:23-19:41 keeps both endpoints; only the interior snaps."""
        slots = MealSchedule(443, 1181, 5).slots()
        assert slots[0] == 443
        assert slots[-1] == 1181
        assert all(slot % SLOT_GRID_MINUTES == 0 for slot in slots[1:-1])

    def test_the_users_quarter_hour_schedule(self) -> None:
        """07:15-19:00 with five meals, as the user asked for it."""
        assert MealSchedule(435, 1140, 5).slots() == (435, 615, 795, 960, 1140)


class TestNormalization:
    """Out-of-range input is clamped, never rejected."""

    @pytest.mark.parametrize(
        ("schedule", "expected"),
        [
            (MealSchedule(480, 1200, 99), MealSchedule(480, 1200, MAX_MEAL_COUNT)),
            (MealSchedule(480, 1200, 0), MealSchedule(480, 1200, MIN_MEAL_COUNT)),
            (MealSchedule(-5, 1200, 4), MealSchedule(0, 1200, 4)),
            (MealSchedule(480, 9999, 4), MealSchedule(480, 1439, 4)),
            # last <= first is pulled forward to leave one grid step of window.
            (MealSchedule(720, 720, 4), MealSchedule(720, 735, 2)),
            (MealSchedule(720, 3, 4), MealSchedule(720, 735, 2)),
            # first cannot sit in the final grid step, or no window remains.
            (MealSchedule(1439, 1439, 2), MealSchedule(1424, 1439, 2)),
            # Count is capped by the grid: 60 minutes hold 5 quarter-hour marks.
            (MealSchedule(480, 540, 6), MealSchedule(480, 540, 5)),
        ],
    )
    def test_clamps_to_the_nearest_legal_schedule(
        self, schedule: MealSchedule, expected: MealSchedule
    ) -> None:
        """Illegal values are pulled into range rather than raising."""
        assert schedule.normalized() == expected

    def test_garbage_still_yields_usable_slots(self) -> None:
        """Wildly invalid input degrades to a schedule, not an exception."""
        assert MealSchedule(9999, -5, 999).slots() == (1424, 1439)


class TestEnforcementEndMinute:
    """The daily cutoff derived from the last meal."""

    def test_default_keeps_the_historical_cutoff(self) -> None:
        """The default schedule still stops enforcing at 22:00."""
        assert DEFAULT_SCHEDULE.enforcement_end_minute == 22 * _H

    def test_tail_follows_the_last_meal(self) -> None:
        """Moving the last meal moves the cutoff with it, to the minute."""
        assert MealSchedule(480, 1095, 4).enforcement_end_minute == 1215

    def test_clamped_to_the_end_of_the_day(self) -> None:
        """A late last meal cannot push the cutoff past midnight.

        An unclamped 1380 + 120 = 1500 would make ``minute < cutoff``
        vacuously true, so the enforcement window would never close.
        """
        assert MealSchedule(480, 1380, 4).enforcement_end_minute == MINUTES_PER_DAY

    def test_follows_the_normalised_last_meal(self) -> None:
        """An inverted window's cutoff agrees with its normalised last slot."""
        schedule = MealSchedule(720, 3, 4)
        assert schedule.enforcement_end_minute == schedule.slots()[-1] + 120


class TestWire:
    """The ``sched:<date>`` wire encoding stays readable by old devices."""

    def test_whole_hour_schedule_encodes_exactly_as_before(self) -> None:
        """No ``fm``/``lm`` keys at all, so the bytes do not change."""
        assert schedule_to_wire(DEFAULT_SCHEDULE) == {"f": 8, "l": 20, "n": 4}

    def test_off_hour_endpoints_add_minute_fields(self) -> None:
        """An off-hour endpoint carries its minute alongside the floor hour."""
        wire = schedule_to_wire(MealSchedule(435, 1181, 5))
        assert wire == {"f": 7, "l": 19, "n": 5, "fm": 435, "lm": 1181}

    def test_unusable_values_decode_to_none(self) -> None:
        """A bool ``f`` is not an int here, exactly as in Dart."""
        assert schedule_from_wire({"f": True, "l": 20, "n": 4}) is None
        assert schedule_from_wire("not a dict") is None


class TestExhaustiveInvariants:
    """Properties that must hold for every input the UI or sync can produce."""

    def test_grid_sweep_yields_ascending_slots_with_exact_endpoints(self) -> None:
        """Sweep every quarter-hour first/last pair at every count.

        The Dart mirror runs the identical loop.  A wire round trip rides
        along, because it is the same sweep's worth of schedules.
        """
        for first in range(0, MINUTES_PER_DAY, SLOT_GRID_MINUTES):
            for last in range(0, MINUTES_PER_DAY, SLOT_GRID_MINUTES):
                for count in range(MIN_MEAL_COUNT, MAX_MEAL_COUNT + 1):
                    schedule = MealSchedule(first, last, count)
                    normalized = schedule.normalized()
                    slots = schedule.slots()
                    assert slots[0] == normalized.first_minute
                    assert slots[-1] == normalized.last_minute
                    assert len(slots) == normalized.count
                    assert all(a < b for a, b in pairwise(slots))
                    assert slots[0] >= 0
                    assert slots[-1] < MINUTES_PER_DAY
                    assert schedule_from_wire(schedule_to_wire(schedule)) == normalized

    def test_off_grid_sweep_stays_strictly_ascending(self) -> None:
        """Odd-minute windows near the capacity cap never repeat a slot."""
        for first in range(0, 120, 7):
            for width in range(15, 200, 11):
                for count in range(MIN_MEAL_COUNT, MAX_MEAL_COUNT + 1):
                    slots = MealSchedule(first, first + width, count).slots()
                    assert all(a < b for a, b in pairwise(slots))
