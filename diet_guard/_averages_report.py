"""Weekly and monthly average intake, and how that average met the budget.

PERIOD AVERAGE SPEC (keep in sync with
``app/lib/services/average_service.dart``):

* the average is over **logged days only** -- ``sum(kcal) / logged_days``.  A
  day you forgot to log is not a zero-calorie day, and counting it as one
  would make every gap in the log read as "well under budget", which is the
  exact opposite of the truth.  ``logged_days`` / ``elapsed_days`` travel with
  the average so a caller can show how much of the period it actually covers.
* the yardstick is the **mean of the per-day budgets over those same logged
  days**, resolved through a
  :class:`~diet_guard._budget_history.BudgetSchedule` -- never today's budget.
  Comparing a past week's intake against a budget you lowered yesterday would
  retroactively reclassify it, which is precisely what
  :mod:`diet_guard._budget_history` exists to prevent.
* bands, reusing the calendar's own over-budget boundary
  (:data:`~diet_guard._daystatus.OVER_BUDGET_YELLOW_CEILING`) so a period and
  its days can never disagree about what "over" means:

  - ``under``:         ``avg_kcal <= avg_budget``
  - ``slightly_over``: ``avg_budget < avg_kcal <= avg_budget * ceiling``
  - ``very_over``:     ``avg_kcal > avg_budget * ceiling``

* **today is excluded.**  A period ending at "now" mixes complete days with
  one that is three hours old, and a half-logged today drags the mean down far
  enough to flip the band.  Every period therefore ends at
  :func:`last_complete_day` -- yesterday -- so "this week" means "this week so
  far, in finished days".  A period with no finished days yet (Monday, or the
  1st) reports ``elapsed_days == 0`` and a ``None`` average rather than a
  flattering fake one.
* weeks are **ISO weeks, Monday through Sunday**; months are calendar months.

Every function here is a pure function of its explicit ``log`` / ``schedule``
/ ``today`` arguments and never reaches into on-disk state, so the band
boundaries and the period edges are testable with synthetic data.
"""

from __future__ import annotations

from datetime import date, timedelta
from typing import TYPE_CHECKING

from diet_guard._averages import PeriodAverage, period_average
from diet_guard._averages_periods import (
    _resolve_today,
    _shift_months,
    last_complete_day,
    month_bounds,
    week_bounds,
)

if TYPE_CHECKING:
    from diet_guard._budget_history import BudgetSchedule
    from diet_guard._state import DayLog

_DAYS_PER_WEEK = 7
_MONTHS_PER_YEAR = 12


def _capped(
    log: DayLog,
    schedule: BudgetSchedule,
    bounds: tuple[date, date],
    ref: date,
) -> PeriodAverage:
    """Average ``bounds``, truncated so it never includes ``ref`` itself.

    The single place the "today is excluded" rule is applied, so a caller
    cannot construct a period that half-counts an unfinished day.
    """
    start, end = bounds
    return period_average(
        log,
        schedule=schedule,
        start=start,
        end=min(end, last_complete_day(ref)),
    )


def weekly_average(
    log: DayLog,
    *,
    schedule: BudgetSchedule,
    weeks_ago: int = 0,
    today: date | None = None,
) -> PeriodAverage:
    """Return the average for an ISO week, ``weeks_ago`` weeks back.

    Args:
        log: A filtered log (see :func:`period_average`).
        schedule: Resolves each day's budget.
        weeks_ago: 0 for the current week (through yesterday), 1 for the
            previous complete week, and so on.
        today: The reference "today"; defaults to the real current date.

    Returns:
        That week's :class:`PeriodAverage`.
    """
    ref = _resolve_today(today)
    anchor = ref - timedelta(weeks=weeks_ago)
    return _capped(log, schedule, week_bounds(anchor), ref)


def monthly_average(
    log: DayLog,
    *,
    schedule: BudgetSchedule,
    months_ago: int = 0,
    today: date | None = None,
) -> PeriodAverage:
    """Return the average for a calendar month, ``months_ago`` months back.

    Args:
        log: A filtered log (see :func:`period_average`).
        schedule: Resolves each day's budget.
        months_ago: 0 for the current month (through yesterday), 1 for the
            previous complete month, and so on.
        today: The reference "today"; defaults to the real current date.

    Returns:
        That month's :class:`PeriodAverage`.
    """
    ref = _resolve_today(today)
    return _capped(log, schedule, month_bounds(_shift_months(ref, months_ago)), ref)


def recent_weeks(
    log: DayLog,
    *,
    schedule: BudgetSchedule,
    count: int,
    today: date | None = None,
) -> tuple[PeriodAverage, ...]:
    """Return the last ``count`` weekly averages, most recent first."""
    ref = _resolve_today(today)
    return tuple(
        weekly_average(log, schedule=schedule, weeks_ago=back, today=ref)
        for back in range(count)
    )


def recent_months(
    log: DayLog,
    *,
    schedule: BudgetSchedule,
    count: int,
    today: date | None = None,
) -> tuple[PeriodAverage, ...]:
    """Return the last ``count`` monthly averages, most recent first."""
    ref = _resolve_today(today)
    return tuple(
        monthly_average(log, schedule=schedule, months_ago=back, today=ref)
        for back in range(count)
    )
