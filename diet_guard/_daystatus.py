"""Per-day budget-adherence status, streaks, and year-to-date tallies.

DAY STATUS SPEC (keep in sync with ``app/lib/services/day_status_service.dart``):

* green: ``total_kcal <= budget``
* yellow: ``budget < total_kcal <= budget * (1 + (1 - BUDGET_WARN_FRACTION))``
* red: ``total_kcal > budget * (1 + (1 - BUDGET_WARN_FRACTION))``
* not_logged: the day is absent from a filtered log (no valid,
  non-tombstoned entries) -- see :func:`diet_guard._state.load_log`.
* ordering, worst to best: not_logged > red > yellow > green.
* the logging streak breaks on a not_logged day.
* the adherence streak breaks on a red or a not_logged day; yellow and green
  both keep it alive.

Every function here is a pure function of an explicit ``log``/``status_map``
argument (never reaching into on-disk state itself), so the boundary matrix
above is trivially testable with synthetic data.  :func:`current_status_map`
is the one exception: a thin convenience wrapper for real UI callers.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
import enum
from typing import TYPE_CHECKING

from diet_guard._budget import daily_budget
from diet_guard._constants import BUDGET_WARN_FRACTION
from diet_guard._state import entry_kcal, load_log, now_local

if TYPE_CHECKING:
    from diet_guard._state import DayLog


class DayStatus(enum.Enum):
    """Qualitative per-day budget-adherence state, worst to best."""

    NOT_LOGGED = "not_logged"
    RED = "red"
    YELLOW = "yellow"
    GREEN = "green"


# The top of the "yellow" band above budget: a margin as wide as
# BUDGET_WARN_FRACTION's margin below 100% (the existing "approaching limit"
# band), so the two bands are symmetric around the budget line.
_OVER_BUDGET_YELLOW_CEILING = 1.0 + (1.0 - BUDGET_WARN_FRACTION)

_LOGGED_STATUSES = frozenset(
    {DayStatus.GREEN, DayStatus.YELLOW, DayStatus.RED},
)
_ADHERENT_STATUSES = frozenset({DayStatus.GREEN, DayStatus.YELLOW})


@dataclass(frozen=True)
class YtdTally:
    """Year-to-date logging/adherence counts.

    Attributes:
        logged_days: Days this year with at least one valid log entry.
        elapsed_days: Days from Jan 1 through the reference date, inclusive.
        adherent_days: Of ``logged_days``, how many were green or yellow.
    """

    logged_days: int
    elapsed_days: int
    adherent_days: int


def day_total_kcal(log: DayLog, day: str) -> float:
    """Return the summed kcal for one ``YYYY-MM-DD`` key in ``log``."""
    return sum(entry_kcal(entry) for entry in log.get(day, []))


def day_status(log: DayLog, day: str, budget: int) -> DayStatus:
    """Classify one day's budget adherence.

    Args:
        log: A filtered log as returned by
            :func:`diet_guard._state.load_log` (only valid, non-tombstoned
            entries; a day with none is simply absent).
        day: The ``YYYY-MM-DD`` date key to classify.
        budget: The daily kcal budget to compare against.

    Returns:
        The day's :class:`DayStatus`.
    """
    if day not in log:
        return DayStatus.NOT_LOGGED
    total = day_total_kcal(log, day)
    if total <= budget:
        return DayStatus.GREEN
    if total <= budget * _OVER_BUDGET_YELLOW_CEILING:
        return DayStatus.YELLOW
    return DayStatus.RED


def status_map(log: DayLog, *, budget: int) -> dict[str, DayStatus]:
    """Return a :class:`DayStatus` for every date key present in ``log``.

    Days with no log entries are simply absent from the result; a caller
    rendering a full calendar treats a missing key as
    :attr:`DayStatus.NOT_LOGGED`.
    """
    return {day: day_status(log, day, budget) for day in log}


def _streak(
    status_map_: dict[str, DayStatus],
    keeps: frozenset[DayStatus],
    *,
    today: date | None = None,
) -> int:
    """Count consecutive days ending at ``today`` whose status is in ``keeps``.

    A ``today`` absent from ``status_map_`` (not yet logged) is skipped
    rather than treated as a break, so the streak does not appear broken
    every morning before the user has eaten; counting resumes from
    yesterday in that case. Any other day missing from ``keeps`` -- logged
    or not -- ends the streak normally.
    """
    day = today if today is not None else now_local().date()
    if status_map_.get(day.isoformat()) is None:
        day -= timedelta(days=1)
    count = 0
    while status_map_.get(day.isoformat()) in keeps:
        count += 1
        day -= timedelta(days=1)
    return count


def logging_streak(
    status_map_: dict[str, DayStatus],
    *,
    today: date | None = None,
) -> int:
    """Return the consecutive-day logging streak ending at ``today``."""
    return _streak(status_map_, _LOGGED_STATUSES, today=today)


def adherence_streak(
    status_map_: dict[str, DayStatus],
    *,
    today: date | None = None,
) -> int:
    """Return the consecutive-day budget-adherence streak ending at ``today``.

    Breaks on a red or not-logged day; green and yellow days both keep it
    alive ("not too aggressively crossed").
    """
    return _streak(status_map_, _ADHERENT_STATUSES, today=today)


def year_to_date_tally(
    status_map_: dict[str, DayStatus],
    *,
    today: date | None = None,
) -> YtdTally:
    """Return this year's logged/elapsed/adherent day counts.

    Args:
        status_map_: Per-day statuses as returned by :func:`status_map`.
        today: The reference "today"; defaults to the real current date.

    Returns:
        Counts of logged days this year, elapsed days so far this year
        (inclusive of ``today``), and how many logged days were adherent.
    """
    ref = today if today is not None else now_local().date()
    elapsed_days = (ref - date(ref.year, 1, 1)).days + 1
    logged_days = 0
    adherent_days = 0
    for key, status in status_map_.items():
        if status is DayStatus.NOT_LOGGED:
            continue
        day = date.fromisoformat(key)
        if day.year != ref.year or day > ref:
            continue
        logged_days += 1
        if status in _ADHERENT_STATUSES:
            adherent_days += 1
    return YtdTally(
        logged_days=logged_days,
        elapsed_days=elapsed_days,
        adherent_days=adherent_days,
    )


def current_status_map() -> dict[str, DayStatus]:
    """Return :func:`status_map` for the real on-disk log and budget.

    Convenience wrapper for UI callers; the pure functions above take
    explicit ``log``/``budget``/``status_map_`` arguments so they stay
    trivially testable with synthetic data.

    Raises:
        BudgetNotInitializedError: If no budget has been set yet.
        BudgetFileCorruptError: If the budget file is corrupt.
    """
    return status_map(load_log(), budget=daily_budget())
