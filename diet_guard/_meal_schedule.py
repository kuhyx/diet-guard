"""The user's eating window and meal count, and the slot hours they imply.

A schedule is three numbers -- the first meal hour, the last meal hour, and how
many meals fall between them inclusive -- from which the intermediate
checkpoints are derived by even division.  ``MealSchedule(8, 20, 5)`` yields
``(8, 11, 14, 17, 20)``.

This module is pure: no clock, no filesystem, no configuration lookup.  Storage
lives in :mod:`diet_guard._meal_schedule_store`, and the slot arithmetic that
consumes a schedule lives in :mod:`diet_guard._slots`.

KEEP IN SYNC WITH ``app/lib/models/meal_schedule.dart``.  The two must agree on
every input, because a device that derives different slots than its peer nags
for checkpoints the other never offers -- and a slot that can never be
satisfied is a permanent lock.  Two rules make that agreement checkable:

* **Integer arithmetic only.**  No floats and no ``round()`` anywhere in the
  derivation.  Python's ``round`` is banker's rounding (``round(2.5) == 2``)
  while Dart's is half-away-from-zero (``2.5.round() == 3``), so any float path
  is a latent cross-language split brain.  ``//`` here, ``~/`` there.
* **Clamp, don't reject.**  Every out-of-range input is normalised to the
  nearest legal schedule rather than raising, so the two languages cannot
  disagree about which inputs are errors.
"""

from __future__ import annotations

from dataclasses import dataclass

# A day's meals must fit inside a day, and the pills that render them have to
# stay legible on a phone at the widest (all-logged) size -- see
# ``app/test/widgets/slot_selector_row_test.dart``.
MIN_MEAL_COUNT = 2
MAX_MEAL_COUNT = 6

FIRST_HOUR = 0
LAST_HOUR = 23

# Grace period after the final checkpoint, before the gate stops firing for
# the day.  Deliberately a constant rather than the slot spacing: it is how
# long you have to log a late dinner, which has nothing to do with how many
# meals you eat.  Tying it to the spacing would stretch the lockout window to
# midnight at four meals, contradicting the "don't trap me overnight" intent
# this cutoff exists to serve.
ENFORCEMENT_TAIL_HOURS = 2

_HOURS_PER_DAY = 24


def _clamp(value: int, low: int, high: int) -> int:
    """Return ``value`` confined to ``[low, high]``."""
    return max(low, min(high, value))


@dataclass(frozen=True)
class MealSchedule:
    """An eating window and the number of meals inside it.

    Attributes:
        first: Hour of the first meal, 0-23.
        last: Hour of the last meal, strictly after ``first``.
        count: Total meals including both endpoints.
    """

    first: int
    last: int
    count: int

    def normalized(self) -> MealSchedule:
        """Return an equivalent schedule guaranteed to satisfy the invariants.

        Ordering matters: ``first`` is clamped into the day, then ``last`` is
        clamped to leave at least one hour of window, then ``count`` is clamped
        to the window's width.  That last clamp is the load-bearing one -- see
        :meth:`slots`.

        Returns:
            A schedule whose ``slots()`` is strictly ascending.
        """
        first = _clamp(self.first, FIRST_HOUR, LAST_HOUR - 1)
        last = _clamp(self.last, first + 1, LAST_HOUR)
        # A window of N hours holds at most N+1 whole-hour checkpoints; asking
        # for more would repeat an hour (see slots()).
        count = _clamp(
            self.count, MIN_MEAL_COUNT, min(MAX_MEAL_COUNT, last - first + 1)
        )
        return MealSchedule(first, last, count)

    def slots(self) -> tuple[int, ...]:
        """Return the meal-slot hours, ascending, endpoints exact.

        Meals are spread evenly across the window and rounded to whole hours by
        integer arithmetic: slot *i* is ``first + (i*span + d//2) // d`` where
        ``span = last - first`` and ``d = count - 1``.  The ``d//2`` term is a
        round-half-up bias applied before the division, which is what keeps
        this float-free.

        Both endpoints land exactly on ``first`` and ``last`` by construction,
        so the eating window is always honoured even when the interior spacing
        has to round.

        The result is strictly ascending because :meth:`normalized` caps
        ``count`` at ``last - first + 1``.  Without that cap a narrow window
        repeats an hour (``08-12`` with 6 meals would give
        ``8, 9, 10, 10, 11, 12``), and since slot hours are used as set
        members, dict keys *and* notification ids, a repeat silently drops a
        checkpoint.

        Returns:
            The slot hours, ascending, of length ``normalized().count``.
        """
        schedule = self.normalized()
        span = schedule.last - schedule.first
        divisions = schedule.count - 1
        return tuple(
            schedule.first + (index * span + divisions // 2) // divisions
            for index in range(schedule.count)
        )

    @property
    def enforcement_end_hour(self) -> int:
        """Return the hour at which slot enforcement stops for the day.

        Clamped to the end of the day: a 23:00 last meal would otherwise put
        the cutoff at 25, making ``hour < cutoff`` vacuously true so the
        enforcement window never closes and the gate can never stop firing.
        """
        return min(self.last + ENFORCEMENT_TAIL_HOURS, _HOURS_PER_DAY)


# The historical hardcoded schedule: 08:00, 12:00, 16:00, 20:00, with the
# enforcement window closing at 22:00.  Still what a device uses before the
# user has ever chosen anything, so upgrading changes no behaviour.
DEFAULT_SCHEDULE = MealSchedule(first=8, last=20, count=4)
