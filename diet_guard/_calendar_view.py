"""Pure month-grid math and status text for the diet_guard History tab.

Split out of :mod:`._gatelock_calendar` so the calendar math -- month-grid
construction, per-cell styling, and the streak/YTD summary lines -- carries no
Tk widget dependency and is unit-tested directly, with no fake Tk in the
loop. Also keeps :mod:`._gatelock_calendar` (the Tk-facing half) under the
repo's 500-line limit.
"""

from __future__ import annotations

import calendar
from dataclasses import dataclass
from datetime import date

from diet_guard._daystatus import (
    DayStatus,
    adherence_streak,
    logging_streak,
    year_to_date_tally,
)
from diet_guard._gatelock_ui import BG, FG
from diet_guard._state import now_local

_NOT_LOGGED_FILL = "#000000"
_NOT_LOGGED_OUTLINE = "#e0e0e0"
_STATUS_COLORS = {
    DayStatus.GREEN: "#33cc66",
    DayStatus.YELLOW: "#e0c33c",
    DayStatus.RED: "#ff5555",
}
_STATUS_TEXT_COLOR = "#003322"
_MUTED = "#9a9a9a"


@dataclass(frozen=True)
class CalendarCell:
    """One day cell in a rendered month grid.

    ``day`` is None for a blank cell outside the displayed month.  ``status``
    is None for a blank cell, a future day (nothing to judge yet), or when no
    budget is set (nothing to color by) -- callers render all three the same
    neutral way, never as a false "not logged" black cell.
    """

    day: int | None
    status: DayStatus | None


def _cell_status(
    day: date,
    status_map_: dict[str, DayStatus] | None,
    today: date,
) -> DayStatus | None:
    """Return the status to render for ``day``, or None for nothing to show.

    A day after ``today`` has not happened yet, and ``status_map_`` being
    None means no budget is set to judge by -- both render neutrally rather
    than as a false "not logged" black cell.
    """
    if day > today or status_map_ is None:
        return None
    return status_map_.get(day.isoformat(), DayStatus.NOT_LOGGED)


def build_month_cells(
    year: int,
    month: int,
    status_map_: dict[str, DayStatus] | None,
    *,
    today: date | None = None,
) -> list[list[CalendarCell]]:
    """Return the month's weeks as a grid of :class:`CalendarCell`.

    Mirrors :func:`calendar.monthcalendar`'s shape (a list of weeks, each
    seven day-of-month ints with 0 for days outside the month), translated
    into cells carrying the status to render.

    Args:
        year: The displayed year.
        month: The displayed month (1-12).
        status_map_: Per-day statuses as returned by
            :func:`diet_guard._daystatus.status_map`, or None if no budget is
            set to classify days by.
        today: The reference "today"; defaults to the real current date.

    Returns:
        A list of weeks, each a list of seven :class:`CalendarCell`.
    """
    ref = today if today is not None else now_local().date()
    grid: list[list[CalendarCell]] = []
    for week in calendar.monthcalendar(year, month):
        row: list[CalendarCell] = []
        for day_num in week:
            if day_num == 0:
                row.append(CalendarCell(day=None, status=None))
                continue
            row.append(
                CalendarCell(
                    day=day_num,
                    status=_cell_status(date(year, month, day_num), status_map_, ref),
                ),
            )
        grid.append(row)
    return grid


def cell_style(status: DayStatus | None) -> tuple[str, str, str]:
    """Return ``(bg, fg, highlightbackground)`` for a cell's status."""
    if status is None:
        return BG, _MUTED, BG
    if status is DayStatus.NOT_LOGGED:
        return _NOT_LOGGED_FILL, FG, _NOT_LOGGED_OUTLINE
    color = _STATUS_COLORS[status]
    return color, _STATUS_TEXT_COLOR, color


def _plural(count: int) -> str:
    """Return "day" or "days" for ``count``."""
    return "day" if count == 1 else "days"


def streaks_text(
    status_map_: dict[str, DayStatus],
    *,
    today: date | None = None,
) -> str:
    """Render the logging and adherence streak line.

    ``today`` defaults to the real current date for live UI use; tests pass
    it explicitly for deterministic streak boundaries.
    """
    logging = logging_streak(status_map_, today=today)
    adherence = adherence_streak(status_map_, today=today)
    return (
        f"Logging streak: {logging} {_plural(logging)}  ·  "
        f"Adherence streak: {adherence} {_plural(adherence)}"
    )


def ytd_text(status_map_: dict[str, DayStatus], *, today: date | None = None) -> str:
    """Render the year-to-date logged/elapsed/adherent tally line.

    ``today`` defaults to the real current date for live UI use; tests pass
    it explicitly for a deterministic elapsed-day count.
    """
    tally = year_to_date_tally(status_map_, today=today)
    return (
        f"This year: logged {tally.logged_days}/{tally.elapsed_days} days  ·  "
        f"{tally.adherent_days} within budget"
    )
