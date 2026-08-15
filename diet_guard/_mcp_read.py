"""The MCP server's read-only tools.

Split from :mod:`diet_guard._mcp` (which now holds the gated write tool) to
hold the repo's 250-line cap.  Importing this module is what *registers* these
tools -- the ``@mcp.tool`` decorators run at import time against the singleton
in :mod:`diet_guard._mcp_server` -- so ``_mcp`` imports it for its side effect
and must keep doing so, however unused the name looks.

The budget invariant lives here as much as in ``_mcp``: no tool in this file
returns the raw budget, the remaining-budget number, the stored body weight or
the protein target.  Only consumed intake and the qualitative band go out.
"""

from __future__ import annotations

from typing import Any

from diet_guard._averages import (
    PeriodAverage,
    band_label,
    monthly_average,
    weekly_average,
)
from diet_guard._budget import BudgetError, current_schedule, daily_budget
from diet_guard._gate import due_slots
from diet_guard._mcp_server import READS_ONLY, mcp
from diet_guard._slots import current_slot, day_slots, slot_label
from diet_guard._state import (
    load_log,
    now_local,
)
from diet_guard._state_today import (
    consumption_band,
    logged_slots_today,
    today_entries,
    today_total_kcal,
    today_total_macros,
)


def _macros_dict(macros: tuple[float, float, float]) -> dict[str, float]:
    """Return a ``(protein, carbs, fat)`` triple as a labelled dict."""
    protein, carbs, fat = macros
    return {"protein": protein, "carbs": carbs, "fat": fat}


def _entry_view(entry: dict[str, object]) -> dict[str, Any]:
    """Project a stored log entry to a safe, JSON-friendly summary.

    Deliberately drops the ``hmac`` field and any unknown keys: the signature
    is internal integrity metadata, not something a client needs.

    Args:
        entry: A stored food-log entry.

    Returns:
        A flat dict of the display-relevant fields.
    """
    return {
        "time": entry.get("time"),
        "desc": entry.get("desc"),
        "kcal": entry.get("kcal"),
        "protein_g": entry.get("protein_g"),
        "carbs_g": entry.get("carbs_g"),
        "fat_g": entry.get("fat_g"),
        "grams": entry.get("grams"),
        "source": entry.get("source"),
        "slot": entry.get("slot"),
    }


# ──────────────────────────────────────────────────────────────
# Read tools (consumed intake + qualitative band only; NEVER the budget number)
# ──────────────────────────────────────────────────────────────


@mcp.tool(title="Today's intake status", annotations=READS_ONLY)
def get_status() -> dict[str, Any]:
    """Return today's intake status without ever revealing the daily budget.

    Reports the calories and macros *consumed* so far, the qualitative
    :func:`consumption_band` (``"on track"`` / ``"approaching limit"`` /
    ``"OVER BUDGET"``, or ``None`` when no budget has been set yet), and the
    meal-slot picture (which slots are due, which are already logged, and the
    current slot). The raw budget number is intentionally withheld -- only the
    band is exposed, mirroring how the CLI status shows a label to an automated
    caller rather than the anchor number.
    """
    try:
        band: str | None = consumption_band()
    except BudgetError:
        # No budget set (or a corrupt file): surface the absence, not a number.
        band = None
    return {
        "consumed_kcal": today_total_kcal(),
        "consumed_macros_g": _macros_dict(today_total_macros()),
        "consumption_band": band,
        "budget_initialized": band is not None,
        "due_slots": [slot_label(slot) for slot in due_slots()],
        "logged_slots": sorted(logged_slots_today()),
        "current_slot": current_slot(now_local()),
    }


@mcp.tool(title="Meals logged today", annotations=READS_ONLY)
def list_today() -> dict[str, Any]:
    """List today's logged meals (valid entries only), newest last.

    Returns the per-entry description, calories, macros, portion, source, and
    slot -- the same data the CLI ``status`` listing renders, minus the internal
    HMAC signature.
    """
    entries = today_entries()
    return {
        "count": len(entries),
        "entries": [_entry_view(entry) for entry in entries],
    }


def _period_view(period: PeriodAverage) -> dict[str, Any]:
    """Render one period for the wire, WITHOUT its average budget.

    ``avg_budget`` is dropped on purpose: it is the daily budget by another
    name, and the module invariant is that the number never leaves via this
    interface. What remains -- the mean intake plus the qualitative band -- is
    the same trade ``get_status`` already makes (a band plus a consumed number
    bounds the budget loosely; the exact figure stays on the machine).
    """
    return {
        "start": period.start,
        "end": period.end,
        "logged_days": period.logged_days,
        "elapsed_days": period.elapsed_days,
        "avg_kcal": period.avg_kcal,
        "band": None if period.band is None else period.band.value,
        "band_label": band_label(period.band),
    }


@mcp.tool(title="Weekly and monthly average intake", annotations=READS_ONLY)
def get_averages() -> dict[str, Any]:
    """Return average kcal/day for this and last week, and this and last month.

    Each period's average is over its *logged* days only and is classified
    ``"under"`` / ``"slightly_over"`` / ``"very_over"`` against the mean of the
    budgets that applied on those same days -- never against today's budget, so
    a budget edit does not retroactively reclassify past weeks.

    Every period ends at **yesterday**: today is still being logged, and a
    half-logged day would drag the mean far enough to flip the band. A period
    with no finished logged day yet reports ``avg_kcal: null`` rather than a
    flattering zero.

    The per-period average budget is deliberately not returned (see the module
    docstring's budget invariant); only the intake and the band are.
    """
    try:
        schedule = current_schedule(default=daily_budget())
    except BudgetError:
        # No budget set, or a corrupt file: no yardstick, so no bands.
        return {"budget_initialized": False, "periods": {}}
    log = load_log()
    periods = {
        "this_week": weekly_average(log, schedule=schedule, weeks_ago=0),
        "last_week": weekly_average(log, schedule=schedule, weeks_ago=1),
        "this_month": monthly_average(log, schedule=schedule, months_ago=0),
        "last_month": monthly_average(log, schedule=schedule, months_ago=1),
    }
    return {
        "budget_initialized": True,
        "excludes_today": True,
        "periods": {name: _period_view(period) for name, period in periods.items()},
    }


@mcp.tool(title="Meal slots for the day", annotations=READS_ONLY)
def get_slots() -> dict[str, Any]:
    """Return the day's fixed meal slots and which one is current.

    Pure schedule information (08:00 / 12:00 / 16:00 / 20:00 by default) with no
    budget or intake data attached.
    """
    return {
        "day_slots": [
            {"hour": slot, "label": slot_label(slot)} for slot in day_slots()
        ],
        "current_slot": current_slot(now_local()),
    }
