"""A schedule edit must not re-open meals already logged that day.

End-to-end through the real public path -- ``log_meal`` writes signed entries
to the (redirected) log, ``record_schedule_change`` stores the schedule, and
``gate_is_due`` / ``logged_slots_today`` read both back -- with nothing mocked
in between.  This is the user-approved satisfaction rule: each logged meal
satisfies the slot *nearest* its recorded minute, and nothing on disk is ever
rewritten.  An exact-match rule would lock the user out for two meals they did
log, the moment they nudged breakfast by fifteen minutes.
"""

from __future__ import annotations

from datetime import UTC, datetime

from diet_guard._estimator import Nutrition
from diet_guard._gate import due_slots, gate_is_due
from diet_guard._meal_schedule import MealSchedule
from diet_guard._meal_schedule_store import record_schedule_change
from diet_guard._state import log_meal
from diet_guard._state_today import logged_slots_today


def _today_at(hour: int, minute: int = 0) -> datetime:
    """Return today's local date at ``hour:minute`` (the log is keyed by today)."""
    now = datetime.now(tz=UTC).astimezone()
    return now.replace(hour=hour, minute=minute, second=0, microsecond=0)


def _log_breakfast_and_snack_then_move_the_schedule() -> None:
    """07:00 and 10:00 logged under 07:00-19:00 x5, then moved to 07:15."""
    record_schedule_change(MealSchedule(420, 1140, 5))
    meal = Nutrition(300, 10, 40, 8, 200, "manual")
    log_meal("oats", meal, slot=420)
    log_meal("apple", meal, slot=600)
    record_schedule_change(MealSchedule(435, 1140, 5))


class TestScheduleMoveKeepsLoggedMeals:
    """07:00/10:00 entries keep covering 07:15/10:15 after the edit."""

    def test_the_moved_slots_are_derived_as_expected(self) -> None:
        """Precondition: the new schedule really moved both checkpoints."""
        assert MealSchedule(435, 1140, 5).slots() == (435, 615, 795, 960, 1140)

    def test_old_entries_satisfy_the_nearest_new_slots(self) -> None:
        """Nearest-slot snapping: 420 -> 435 and 600 -> 615."""
        _log_breakfast_and_snack_then_move_the_schedule()
        assert logged_slots_today() == {435, 615}

    def test_nothing_is_due_at_eleven(self) -> None:
        """Both elapsed checkpoints are covered, so the gate stays down."""
        _log_breakfast_and_snack_then_move_the_schedule()
        assert not gate_is_due(_today_at(11))

    def test_the_next_unlogged_slot_still_falls_due(self) -> None:
        """Snapping is not a free pass: 13:15 is due once it arrives."""
        _log_breakfast_and_snack_then_move_the_schedule()
        assert due_slots(_today_at(13, 15)) == (795,)

    def test_the_moved_first_slot_opens_on_its_minute(self) -> None:
        """With nothing logged, 07:15 is due at 07:15 and not at 07:14."""
        record_schedule_change(MealSchedule(435, 1140, 5))
        assert not gate_is_due(_today_at(7, 14))
        assert due_slots(_today_at(7, 15)) == (435,)
