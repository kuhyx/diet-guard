"""Weekly-average planner: what to eat on the rest of the week's days.

"I want to average N kcal this week, and on Monday I ate 2500 -- what do I
eat on the other days?" The week is Monday-Sunday around ``today``. A day is
*known* when the user typed a number for it, or when it is already over
(before ``today``) and has meals in the log. Every other day -- today
included, since it is still in progress -- shares what is left evenly::

    per_day = (target x 7 - sum(known)) / remaining_days

Informational only, like the calorie table: it never touches the budget.
Pure over its arguments; mirrored in ``app/lib/services/week_plan.dart`` and
gated by the shared ``tests/fixtures/body_calc.json``.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta

from diet_guard._body_calc import half_up
from diet_guard._body_energy import MIN_TARGET_KCAL

__all__ = ["WEEKDAYS", "DayPlan", "WeekPlan", "plan_week", "week_start"]

WEEKDAYS: tuple[str, ...] = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")


@dataclass(frozen=True)
class DayPlan:
    """One day of the plan.

    Attributes:
        day: ``YYYY-MM-DD``.
        weekday: ``Mon`` .. ``Sun``.
        kcal: What was eaten (known) or should be eaten (planned).
        source: ``typed``, ``logged``, ``plan``, or ``unlogged`` -- a day
            already over with nothing in the log, planned like a remaining
            day (an unlogged day is not a zero-kcal day) so the screens can
            ask for the real number.
    """

    day: str
    weekday: str
    kcal: int
    source: str


@dataclass(frozen=True)
class WeekPlan:
    """The whole week.

    Attributes:
        days: Monday .. Sunday.
        target_avg: The weekly average aimed for.
        per_remaining: kcal for each ``plan`` day, or None when none remain.
        week_avg: The average the plan produces (equals ``target_avg`` up to
            rounding when anything remains; the achieved average otherwise).
    """

    days: tuple[DayPlan, ...]
    target_avg: int
    per_remaining: int | None
    week_avg: float

    @property
    def below_floor(self) -> bool:
        """Whether the remaining days would have to go under 1200 kcal."""
        return self.per_remaining is not None and self.per_remaining < MIN_TARGET_KCAL


def _open_source(monday: date, index: int, today: date) -> str:
    """``unlogged`` for a past day without data, ``plan`` for today onward."""
    return "unlogged" if monday + timedelta(days=index) < today else "plan"


def week_start(today: date) -> date:
    """The Monday of ``today``'s week."""
    return today - timedelta(days=today.weekday())


def plan_week(
    today: date,
    target_avg: int,
    logged: dict[str, float],
    typed: dict[int, int],
) -> WeekPlan:
    """Plan the rest of ``today``'s week.

    Args:
        today: The current local date.
        target_avg: Desired mean kcal/day over the seven days.
        logged: ``YYYY-MM-DD`` -> kcal eaten, from the food log. Only days
            before ``today`` are used.
        typed: Weekday index (0 = Monday) -> kcal the user typed; wins over
            the log, and may name any day (a planned feast on Saturday too).
    """
    monday = week_start(today)
    known: dict[int, tuple[int, str]] = {}
    for index in range(7):
        day = monday + timedelta(days=index)
        if index in typed:
            known[index] = (typed[index], "typed")
        elif day < today and day.isoformat() in logged:
            known[index] = (int(half_up(logged[day.isoformat()])), "logged")
    remaining = 7 - len(known)
    eaten = sum(kcal for kcal, _ in known.values())
    per = int(half_up((target_avg * 7 - eaten) / remaining)) if remaining else None
    days = tuple(
        DayPlan(
            day=(monday + timedelta(days=index)).isoformat(),
            weekday=WEEKDAYS[index],
            kcal=known[index][0] if index in known else int(per or 0),
            source=known[index][1]
            if index in known
            else _open_source(monday, index, today),
        )
        for index in range(7)
    )
    return WeekPlan(
        days=days,
        target_avg=target_avg,
        per_remaining=per,
        week_avg=sum(d.kcal for d in days) / 7,
    )
