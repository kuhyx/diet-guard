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

import calendar
from datetime import date, timedelta

from diet_guard._state import now_local

_DAYS_PER_WEEK = 7
_MONTHS_PER_YEAR = 12


def last_complete_day(today: date) -> date:
    """Return the last day whose log is finished: the day before ``today``."""
    return today - timedelta(days=1)


def week_bounds(day: date) -> tuple[date, date]:
    """Return the Monday and Sunday of the ISO week containing ``day``."""
    monday = day - timedelta(days=day.weekday())
    return monday, monday + timedelta(days=_DAYS_PER_WEEK - 1)


def month_bounds(day: date) -> tuple[date, date]:
    """Return the first and last dates of ``day``'s calendar month."""
    last = calendar.monthrange(day.year, day.month)[1]
    return day.replace(day=1), day.replace(day=last)


def _shift_months(day: date, months: int) -> date:
    """Return the first of the month ``months`` before ``day``'s month."""
    index = day.year * _MONTHS_PER_YEAR + (day.month - 1) - months
    year, month = divmod(index, _MONTHS_PER_YEAR)
    return date(year, month + 1, 1)


def _resolve_today(today: date | None) -> date:
    """Return ``today`` or the real current local date when it is None."""
    return today if today is not None else now_local().date()
