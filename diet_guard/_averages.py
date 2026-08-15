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

from dataclasses import dataclass
from datetime import date, timedelta
import enum
from typing import TYPE_CHECKING

from diet_guard._daystatus import OVER_BUDGET_YELLOW_CEILING, day_total_kcal

if TYPE_CHECKING:
    from diet_guard._budget_history import BudgetSchedule
    from diet_guard._state import DayLog

_DAYS_PER_WEEK = 7
_MONTHS_PER_YEAR = 12


class AverageBand(enum.Enum):
    """How a period's average intake compared with its average budget."""

    UNDER = "under"
    SLIGHTLY_OVER = "slightly_over"
    VERY_OVER = "very_over"


_BAND_LABELS = {
    AverageBand.UNDER: "under",
    AverageBand.SLIGHTLY_OVER: "slightly over",
    AverageBand.VERY_OVER: "very over",
}

_NO_DATA_LABEL = "no data"


def band_label(band: AverageBand | None) -> str:
    """Return the human phrase for ``band``, or ``"no data"`` for None."""
    return _NO_DATA_LABEL if band is None else _BAND_LABELS[band]


@dataclass(frozen=True)
class PeriodAverage:
    """One period's mean intake and how it compared with the mean budget.

    Attributes:
        start: ``YYYY-MM-DD``, the period's first day (inclusive).
        end: ``YYYY-MM-DD``, the period's last *complete* day (inclusive);
            earlier than ``start`` when the period has none yet.
        logged_days: Days in the range that carry at least one valid entry.
        elapsed_days: Complete days in the range, logged or not.
        avg_kcal: Mean kcal across ``logged_days``, or None when that is zero.
        avg_budget: Mean daily budget across those same days, or None.
        band: The :class:`AverageBand`, or None when there is nothing to judge.
    """

    start: str
    end: str
    logged_days: int
    elapsed_days: int
    avg_kcal: float | None
    avg_budget: float | None
    band: AverageBand | None


def band_for(avg_kcal: float, avg_budget: float) -> AverageBand:
    """Classify ``avg_kcal`` against ``avg_budget``.

    Args:
        avg_kcal: The period's mean daily intake.
        avg_budget: The period's mean daily budget.

    Returns:
        The matching :class:`AverageBand`.
    """
    if avg_kcal <= avg_budget:
        return AverageBand.UNDER
    if avg_kcal <= avg_budget * OVER_BUDGET_YELLOW_CEILING:
        return AverageBand.SLIGHTLY_OVER
    return AverageBand.VERY_OVER


def period_average(
    log: DayLog,
    *,
    schedule: BudgetSchedule,
    start: date,
    end: date,
) -> PeriodAverage:
    """Average ``log``'s intake over ``[start, end]`` and classify it.

    Args:
        log: A filtered log as returned by
            :func:`diet_guard._state.load_log` (only valid, non-tombstoned
            entries; a day with none is simply absent).
        schedule: Resolves the budget that applied on each individual day.
        start: First day of the period (inclusive).
        end: Last day of the period (inclusive); an ``end`` before ``start``
            is an empty period, not an error.

    Returns:
        The period's :class:`PeriodAverage`.
    """
    totals: list[float] = []
    budgets: list[int] = []
    day = start
    while day <= end:
        key = day.isoformat()
        if key in log:
            totals.append(day_total_kcal(log, key))
            budgets.append(schedule.for_day(key))
        day += timedelta(days=1)
    elapsed = max((end - start).days + 1, 0)
    if not totals:
        return PeriodAverage(
            start=start.isoformat(),
            end=end.isoformat(),
            logged_days=0,
            elapsed_days=elapsed,
            avg_kcal=None,
            avg_budget=None,
            band=None,
        )
    avg_kcal = sum(totals) / len(totals)
    avg_budget = sum(budgets) / len(budgets)
    return PeriodAverage(
        start=start.isoformat(),
        end=end.isoformat(),
        logged_days=len(totals),
        elapsed_days=elapsed,
        avg_kcal=avg_kcal,
        avg_budget=avg_budget,
        band=band_for(avg_kcal, avg_budget),
    )
