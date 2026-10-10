"""Tests for _slots.nearest_slot / satisfied_slots.

How a recorded slot minute -- possibly written under an older schedule, or as a
legacy whole hour -- counts toward today's checkpoints.  Split out of
test_slots.py for the repo's 250-line cap.
"""

from __future__ import annotations

from diet_guard._meal_schedule import DEFAULT_SCHEDULE, MealSchedule
from diet_guard._slots import nearest_slot, satisfied_slots


class TestNearestSlot:
    """The closest slot, ties to the earlier."""

    def test_exact_slot_is_itself(self) -> None:
        """A minute that is a slot maps to that slot."""
        assert nearest_slot(720, DEFAULT_SCHEDULE) == 720

    def test_exact_halfway_goes_to_the_earlier_slot(self) -> None:
        """10:00 is equidistant from 08:00 and 12:00; the earlier wins."""
        assert nearest_slot(600, DEFAULT_SCHEDULE) == 480
        assert nearest_slot(601, DEFAULT_SCHEDULE) == 720

    def test_outside_the_window_clamps_to_the_ends(self) -> None:
        """Before the first slot and after the last, the end slots win."""
        assert nearest_slot(-60, DEFAULT_SCHEDULE) == 480
        assert nearest_slot(1800, DEFAULT_SCHEDULE) == 1200


class TestSatisfiedSlots:
    """Which checkpoints a day's recorded slot minutes cover."""

    def test_empty_input_satisfies_nothing(self) -> None:
        """No meals, no satisfied slots."""
        assert satisfied_slots([], DEFAULT_SCHEDULE) == set()

    def test_meals_survive_a_schedule_move(self) -> None:
        """The user's case: logged at 07:00 and 10:00, then moved to 07:15.

        Under 07:15-19:00 x5 the slots are 07:15, 10:15, 13:15, 16:00, 19:00;
        each old meal lands on its own nearest slot, so both still count.
        """
        moved = MealSchedule(435, 1140, 5)
        assert satisfied_slots([420, 600], moved) == {435, 615}

    def test_two_meals_on_one_slot_satisfy_only_that_slot(self) -> None:
        """A double breakfast does not also clear lunch."""
        assert satisfied_slots([480, 540], DEFAULT_SCHEDULE) == {480}

    def test_legacy_hour_entries_map_onto_five_meals(self) -> None:
        """Entries tagged 08 and 12 under four meals, read under five."""
        assert satisfied_slots([480, 720], MealSchedule(480, 1200, 5)) == {480, 660}
