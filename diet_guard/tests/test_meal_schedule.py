"""Tests for the pure meal-schedule derivation.

The vector table below is duplicated verbatim in
``app/test/models/meal_schedule_test.dart``.  KEEP THE TWO IN SYNC: it is the
only thing that catches a Python/Dart divergence before it reaches a device,
and a divergence there means one device nags for a checkpoint the other never
offers -- a slot that can never be satisfied, i.e. a permanent lock.
"""

from __future__ import annotations

import pytest

from diet_guard._meal_schedule import (
    DEFAULT_SCHEDULE,
    MAX_MEAL_COUNT,
    MIN_MEAL_COUNT,
    MealSchedule,
)

# (first, last, count) -> expected slot hours.  Shared with the Dart mirror.
SCHEDULE_VECTORS: list[tuple[int, int, int, tuple[int, ...]]] = [
    # The eating window the user described, at every supported meal count.
    (8, 20, 2, (8, 20)),
    (8, 20, 3, (8, 14, 20)),
    (8, 20, 4, (8, 12, 16, 20)),  # today's hardcoded schedule
    (8, 20, 5, (8, 11, 14, 17, 20)),  # the user's stated example
    (8, 20, 6, (8, 10, 13, 15, 18, 20)),
    # A window that does not divide evenly: 14 hours across 3 gaps.
    (7, 21, 4, (7, 12, 16, 21)),
    (7, 21, 5, (7, 11, 14, 18, 21)),
    (9, 19, 4, (9, 12, 16, 19)),
    # Narrow windows: count is capped at the number of whole hours available,
    # so the slots stay distinct instead of repeating an hour.
    (8, 12, 6, (8, 9, 10, 11, 12)),
    (8, 10, 5, (8, 9, 10)),
    (8, 9, 4, (8, 9)),
    # Whole-day extremes.
    (0, 23, 6, (0, 5, 9, 14, 18, 23)),
    (0, 1, 2, (0, 1)),
]


class TestSlots:
    """Slot derivation from a schedule."""

    @pytest.mark.parametrize(("first", "last", "count", "expected"), SCHEDULE_VECTORS)
    def test_matches_shared_vectors(
        self, first: int, last: int, count: int, expected: tuple[int, ...]
    ) -> None:
        """Each shared vector derives its documented slot hours."""
        assert MealSchedule(first, last, count).slots() == expected

    def test_default_is_the_historical_schedule(self) -> None:
        """The default reproduces the hours that used to be hardcoded."""
        assert DEFAULT_SCHEDULE.slots() == (8, 12, 16, 20)

    def test_endpoints_are_exact_when_spacing_rounds(self) -> None:
        """Rounding the interior never drags an endpoint off the window."""
        slots = MealSchedule(8, 20, 6).slots()
        assert slots[0] == 8
        assert slots[-1] == 20


class TestNormalization:
    """Out-of-range input is clamped, never rejected."""

    @pytest.mark.parametrize(
        ("schedule", "expected"),
        [
            (MealSchedule(8, 20, 99), MealSchedule(8, 20, MAX_MEAL_COUNT)),
            (MealSchedule(8, 20, 0), MealSchedule(8, 20, MIN_MEAL_COUNT)),
            (MealSchedule(-5, 20, 4), MealSchedule(0, 20, 4)),
            (MealSchedule(8, 99, 4), MealSchedule(8, 23, 4)),
            # last <= first is pulled forward to leave a one-hour window.
            (MealSchedule(12, 12, 4), MealSchedule(12, 13, 2)),
            (MealSchedule(12, 3, 4), MealSchedule(12, 13, 2)),
            # first cannot occupy the final hour, or no window would remain.
            (MealSchedule(23, 23, 2), MealSchedule(22, 23, 2)),
        ],
    )
    def test_clamps_to_the_nearest_legal_schedule(
        self, schedule: MealSchedule, expected: MealSchedule
    ) -> None:
        """Illegal values are pulled into range rather than raising."""
        assert schedule.normalized() == expected

    def test_garbage_still_yields_usable_slots(self) -> None:
        """Wildly invalid input degrades to a schedule, not an exception."""
        assert MealSchedule(99, -5, 999).slots() == (22, 23)


class TestEnforcementEndHour:
    """The daily cutoff derived from the last meal."""

    def test_default_keeps_the_historical_cutoff(self) -> None:
        """The default schedule still stops enforcing at 22:00."""
        assert DEFAULT_SCHEDULE.enforcement_end_hour == 22

    def test_tail_follows_the_last_meal(self) -> None:
        """Moving the last meal moves the cutoff with it."""
        assert MealSchedule(8, 18, 4).enforcement_end_hour == 20

    def test_clamped_to_the_end_of_the_day(self) -> None:
        """A late last meal cannot push the cutoff past midnight.

        An unclamped 23 + 2 = 25 would make ``hour < cutoff`` vacuously true,
        so the enforcement window would never close.
        """
        assert MealSchedule(8, 23, 4).enforcement_end_hour == 24


class TestExhaustiveInvariants:
    """Properties that must hold for every input the UI or sync can produce."""

    def test_every_input_yields_ascending_slots_with_exact_endpoints(self) -> None:
        """Sweep the whole input space, including out-of-range values.

        This is the cheap half of the cross-language parity guarantee; the
        Dart mirror runs the identical sweep.
        """
        for first in range(-2, 26):
            for last in range(-2, 26):
                for count in range(-2, 10):
                    schedule = MealSchedule(first, last, count)
                    normalized = schedule.normalized()
                    slots = schedule.slots()

                    assert slots[0] == normalized.first
                    assert slots[-1] == normalized.last
                    assert len(slots) == normalized.count
                    assert len(set(slots)) == len(slots)
                    assert list(slots) == sorted(slots)
                    assert MIN_MEAL_COUNT <= len(slots) <= MAX_MEAL_COUNT
