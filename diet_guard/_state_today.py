"""Today's read model over the signed food log.

Split out of :mod:`._state` to keep both files under the repo's 250-line
limit.  Everything here is *derived*: it reads through
:func:`diet_guard._state.load_log` and never touches the file itself.

That division is deliberate rather than cosmetic. ``FOOD_LOG_FILE`` and the
two functions that open it stay in :mod:`._state`, because
``tests/conftest.py`` redirects the log by patching
``diet_guard._state.FOOD_LOG_FILE``. Moving a reader of that constant into
this module would leave the patch pointing at a name nothing reads any more --
it would still resolve, ``check_patch_targets.py`` would still exit 0, and the
suite would quietly write to the real ``~/.local/share/diet_guard``.

The names are re-exported from :mod:`._state`, which is where a dozen modules
already import them from.
"""

from __future__ import annotations

from diet_guard._budget import daily_budget
from diet_guard._constants import BUDGET_WARN_FRACTION
from diet_guard._state import (
    _entry_float,
    _today,
    entry_kcal,
    load_log,
)

__all__ = [
    "consumption_band",
    "logged_slots_today",
    "remaining_budget",
    "today_entries",
    "today_total_kcal",
    "today_total_macros",
]


def today_entries() -> list[dict[str, object]]:
    """Return today's valid log entries (possibly empty)."""
    return load_log().get(_today(), [])


def today_total_kcal() -> float:
    """Return total kcal logged today across valid entries."""
    total = sum(entry_kcal(entry) for entry in today_entries())
    return round(total, 1)


def today_total_macros() -> tuple[float, float, float]:
    """Return today's total ``(protein_g, carbs_g, fat_g)`` across valid entries.

    Returned as a fixed ``(protein, carbs, fat)`` triple so callers (the gate
    dashboard, the CLI status) can show how the day's macros are stacking up
    next to the calorie total.

    Returns:
        The summed protein, carbohydrate, and fat grams, each rounded to 0.1 g.
    """
    entries = today_entries()
    protein = sum(_entry_float(entry, "protein_g") for entry in entries)
    carbs = sum(_entry_float(entry, "carbs_g") for entry in entries)
    fat = sum(_entry_float(entry, "fat_g") for entry in entries)
    return round(protein, 1), round(carbs, 1), round(fat, 1)


def logged_slots_today() -> set[int]:
    """Return the set of meal-slot hours already covered by today's log.

    Only valid (HMAC-verified) entries count, so stripping entries to dodge a
    checkpoint makes that slot reappear as unsatisfied -- the fail-closed
    direction.  An entry without a ``slot`` field (e.g. a snack logged with no
    checkpoint) contributes calories but satisfies no slot.

    Nothing produces a slot-less entry any more: the phone's "Snack" chip was
    removed on 2026-08-14, and every remaining writer resolves a concrete hour
    through ``slot_for_log`` -- the CLI (:mod:`_cli`), the gate
    (:mod:`_gatelock_mealflow`) and the MCP tool (:mod:`_mcp`, which falls back
    to it whenever its ``slot`` argument is omitted or None).  The check below
    is still load-bearing for entries already on disk and arriving over sync --
    removing it would make every historical snack retroactively satisfy a meal
    slot.

    Returns:
        The distinct integer slot hours logged today (possibly empty).
    """
    slots: set[int] = set()
    for entry in today_entries():
        value = entry.get("slot")
        if isinstance(value, int) and not isinstance(value, bool):
            slots.add(value)
    return slots


def remaining_budget() -> float:
    """Return kcal remaining against the daily budget (may be negative).

    Raises:
        BudgetError: If the budget is uninitialized or its file is corrupt;
            the caller decides whether to guide the user or fail closed.
    """
    return round(daily_budget() - today_total_kcal(), 1)


def consumption_band() -> str:
    """Return a qualitative band for today's intake, never revealing the budget.

    Mirrors how the focus daemon surfaces "at home?" rather than the raw
    coordinates: the caller learns whether to worry, not the number behind the
    threshold.  The threshold still leaks by boundary-probing (watch the label
    flip), so this hides the anchor, it does not make the budget unrecoverable.

    Returns:
        ``"OVER BUDGET"``, ``"approaching limit"``, or ``"on track"``.

    Raises:
        BudgetError: Propagated from :func:`daily_budget` for the caller to
            translate into guidance.
    """
    budget = daily_budget()
    consumed = today_total_kcal()
    if consumed >= budget:
        return "OVER BUDGET"
    if consumed >= budget * BUDGET_WARN_FRACTION:
        return "approaching limit"
    return "on track"
