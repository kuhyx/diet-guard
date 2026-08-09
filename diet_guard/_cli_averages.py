"""CLI handler for the ``averages`` subcommand.

Split out from :mod:`diet_guard._cli` for the same reason
:mod:`diet_guard._cli_sync` is: that module is already close to the repo's
500-line cap.

The daily budget is printed here on purpose.  It is "hidden" only in the sense
of never leaving this machine (see :mod:`diet_guard._constants`), and an
average intake with no yardstick beside it is unreadable -- "2310 kcal/day,
slightly over" invites the obvious "over *what*?".  The MCP server's
equivalent tool deliberately makes the opposite trade and returns the band
alone; see :mod:`diet_guard._mcp`.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from diet_guard._averages import (
    band_label,
    monthly_average,
    weekly_average,
)
from diet_guard._budget import (
    BudgetFileCorruptError,
    BudgetNotInitializedError,
    current_schedule,
    daily_budget,
)
from diet_guard._state import load_log

if TYPE_CHECKING:
    import argparse
    from collections.abc import Callable

    from diet_guard._averages import PeriodAverage
    from diet_guard._budget_history import BudgetSchedule

# Width of the leading period label, so the numbers line up in a column.
_LABEL_WIDTH = 11


def register_averages_subparser(sub: argparse._SubParsersAction) -> None:
    """Register the ``averages`` subcommand on ``sub``."""
    sub.add_parser(
        "averages",
        help="Average kcal/day this and last week, and this and last month.",
    )


def _format_period(label: str, period: PeriodAverage) -> str:
    """Render one period as a single aligned line.

    Args:
        label: The period's name, e.g. ``"this week"``.
        period: The computed average.

    Returns:
        A line ending in the coverage count, or a short "nothing yet" line
        when the period has no logged day to average.
    """
    head = f"{label:<{_LABEL_WIDTH}} {period.start}..{period.end}"
    if period.avg_kcal is None or period.avg_budget is None:
        return f"{head}  no logged days yet"
    return (
        f"{head}  {period.avg_kcal:.0f} kcal/day  -  "
        f"{band_label(period.band)} (budget {period.avg_budget:.0f})  "
        f"[{period.logged_days}/{period.elapsed_days} days logged]"
    )


def _emit_periods(emit: Callable[[str], None], schedule: BudgetSchedule) -> None:
    """Print the four period lines against ``schedule``."""
    log = load_log()
    rows = (
        ("this week", weekly_average(log, schedule=schedule, weeks_ago=0)),
        ("last week", weekly_average(log, schedule=schedule, weeks_ago=1)),
        ("this month", monthly_average(log, schedule=schedule, months_ago=0)),
        ("last month", monthly_average(log, schedule=schedule, months_ago=1)),
    )
    for label, period in rows:
        emit(_format_period(label, period))


def cmd_averages(emit: Callable[[str], None]) -> int:
    """Print weekly and monthly average intake and its budget band.

    Every period ends at *yesterday*: today is still being logged, and half a
    day of entries would drag the mean far enough to flip the band (see
    :mod:`diet_guard._averages`).

    Args:
        emit: A one-line output sink (``_cli._emit``, passed in rather than
            imported so this module has no reach-in dependency on ``_cli``).

    Returns:
        0 once the periods are printed, 1 when no usable budget exists to
        judge them against.
    """
    try:
        budget = daily_budget()
    except BudgetNotInitializedError:
        emit("budget not set - run: python -m diet_guard init")
        return 1
    except BudgetFileCorruptError:
        emit("budget file corrupt - re-run init")
        return 1
    emit("averages exclude today, which is still being logged.")
    _emit_periods(emit, current_schedule(default=budget))
    return 0
