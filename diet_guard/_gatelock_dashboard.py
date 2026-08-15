"""The gate's running "how am I doing today" dashboard.

Split out of :mod:`._gatelock_mealflow` to keep every gate module under the
repo's 250-line limit.  ``_GateDashboard`` sits between
:class:`~diet_guard._gatelock_nutrition._GateNutrition` and
:class:`~diet_guard._gatelock_mealflow._GateMealFlow` in the mixin chain and
owns only the *read* side: the prominent calorie headline and the detail panel
beneath it.  Nothing here writes state, so it can be recomputed at any point
in the meal flow.
"""

from __future__ import annotations

from diet_guard._budget import BudgetError, daily_budget, protein_target_g
from diet_guard._gatelock_nutrition import _GateNutrition
from diet_guard._state import (
    entry_kcal,
    today_entries,
    today_total_kcal,
    today_total_macros,
)

# How many recent meals the dashboard lists.
_DASHBOARD_ROWS = 5
# ISO timestamp "YYYY-MM-DDTHH:MM:SS": HH:MM is characters 11..16.
_TIME_SLICE = slice(11, 16)
# Width a meal description is truncated to in the dashboard.
_DASH_DESC_WIDTH = 22

__all__ = ["_GateDashboard"]


class _GateDashboard(_GateNutrition):
    """The calorie headline and detail panel for the day so far."""

    def _refresh_dashboard(self) -> None:
        """Recompute the prominent calorie headline and the detail panel."""
        self._vars.cal_headline.set(self._cal_headline_text())
        self._vars.dashboard.set(self._dashboard_text())

    def _cal_headline_text(self) -> str:
        """Return the big calories-today line: consumed, target, and remaining."""
        consumed = today_total_kcal()
        try:
            budget = daily_budget()
        except (BudgetError, OSError):
            return f"{consumed:g} kcal today"
        return (
            f"{consumed:g} / {budget:g} kcal   ·   {round(budget - consumed, 1):g} left"
        )

    def _dashboard_text(self) -> str:
        """Build the detail panel: recent meals, then macros and protein."""
        lines = ["── Today ───────────────────────────────"]
        entries = today_entries()
        if entries:
            for entry in entries[-_DASHBOARD_ROWS:]:
                clock = str(entry.get("time", ""))[_TIME_SLICE]
                desc = str(entry.get("desc", "?"))[:_DASH_DESC_WIDTH]
                lines.append(
                    f"  {clock:>5}  {desc:<{_DASH_DESC_WIDTH}}  "
                    f"{entry_kcal(entry):>5.0f} kcal",
                )
        else:
            lines.append("  (nothing logged yet today)")
        protein, carbs, fat = today_total_macros()
        lines.append(f"  macros so far:  P{protein:g}  C{carbs:g}  F{fat:g}  g")
        target = protein_target_g()
        if target is not None:
            left = round(target - protein, 1)
            lines.append(f"  protein {protein:g} / {target:g} g  ({left:g} g left)")
        return "\n".join(lines)
