"""CLI handler for the ``ate`` subcommand.

Split out of :mod:`diet_guard._cli` to hold the repo's 250-line cap, following
the same thin-per-subcommand-handler shape as ``_cli_gate.py`` (``gate``) and
``_cli_sync.py`` (``sync``).  The portion/macro value objects live here rather
than in ``_cli`` because ``_cmd_ate`` is their only consumer -- the argparse
layer builds them and hands them straight over.

This is also where a local write turns into a publish: see
:func:`diet_guard._sync_events.publish_after_log` for why that is event-driven
rather than a periodic timer.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from diet_guard._foodbank import remember_food
from diet_guard._portions import DEFAULT_ITEM_GRAMS, estimate_unit_grams
from diet_guard._resolve import ManualMacros, resolve_nutrition
from diet_guard._slots import slot_for_log
from diet_guard._state import log_meal, now_local
from diet_guard._sync_events import publish_after_log

if TYPE_CHECKING:
    from collections.abc import Callable


@dataclass(frozen=True)
class ManualMacroArgs:
    """User-supplied calories/macros for ``ate``, all optional.

    Grouping these keeps :func:`cmd_ate` within the argument-count limit and
    makes "manual values were supplied" a single, testable value object.

    Attributes:
        kcal: Calories entered manually (None means look the food up instead).
        protein: Protein grams, recorded alongside ``kcal``.
        carbs: Carbohydrate grams, recorded alongside ``kcal``.
        fat: Fat grams, recorded alongside ``kcal``.
    """

    kcal: float | None
    protein: float | None
    carbs: float | None
    fat: float | None


@dataclass(frozen=True)
class Portion:
    """How much was eaten and the basis for any typed macros.

    Grouped so :func:`cmd_ate` stays within the argument-count limit.

    Attributes:
        grams: Explicit grams eaten, or None.
        count: Number of items eaten (an alternative to ``grams``), or None.
        per_grams: Reference weight the typed macros are stated for (e.g. 100
            for a per-100 g label), or None to treat the macros as totals.
    """

    grams: float | None
    count: float | None
    per_grams: float | None


def eaten_grams(
    description: str,
    portion: Portion,
) -> tuple[float | None, str | None]:
    """Resolve how many grams were eaten, plus a note if a weight was assumed.

    A count of items is turned into grams via the staple's unit weight; an
    unknown item falls back to a default weight, with a note so the estimate is
    never silent.

    Args:
        description: The food name (used to look up a per-item weight).
        portion: The user's portion inputs.

    Returns:
        ``(grams, note)`` where ``grams`` may be None (no portion given) and
        ``note`` is a one-line caveat to print, or None.
    """
    if portion.count is not None:
        unit = estimate_unit_grams(description)
        if unit is None:
            return (
                portion.count * DEFAULT_ITEM_GRAMS,
                f"(assumed {DEFAULT_ITEM_GRAMS:g} g per item; "
                "pass --grams to be exact)",
            )
        return portion.count * unit, None
    return portion.grams, None


def cmd_ate(
    emit: Callable[[str], None],
    print_summary: Callable[[], None],
    description: str,
    portion: Portion,
    macros: ManualMacroArgs,
) -> int:
    """Resolve and log a meal, tag its slot, bank it, publish, print the total.

    Resolution order is manual, then food bank, then the staple table, then
    Open Food Facts (see :func:`resolve_nutrition`).  A per-item count or a
    per-reference macro basis is converted to the amount actually eaten first,
    and the food is remembered so next time it is served from local history.

    Args:
        emit: A one-line output sink (``_cli._emit``, passed in rather than
            imported -- see ``_cli_sync.cmd_sync`` for why).
        print_summary: Prints today's total and remaining budget.
        description: The food as the user typed it.
        portion: How much was eaten.
        macros: Any manually supplied calories/macros.

    Returns:
        0 once logged, or 1 when the food could not be resolved at all.
    """
    eaten, note = eaten_grams(description, portion)
    if note is not None:
        emit(note)
    manual_macros = (
        ManualMacros(
            kcal=macros.kcal,
            protein=macros.protein or 0.0,
            carbs=macros.carbs or 0.0,
            fat=macros.fat or 0.0,
            per_grams=portion.per_grams,
        )
        if macros.kcal is not None
        else None
    )
    nutrition = resolve_nutrition(
        description,
        grams=eaten,
        manual_macros=manual_macros,
    )
    if nutrition is None:
        emit(
            f'no food bank, staple, or Open Food Facts match for "{description}". '
            "re-run with --kcal <number> to log it manually.",
        )
        return 1
    log_meal(description, nutrition, slot_for_log(now_local()))
    remember_food(description, nutrition)
    macro_str = f"P{nutrition.protein_g:g} C{nutrition.carbs_g:g} F{nutrition.fat_g:g}"
    portion_str = f"{nutrition.grams:g} g" if nutrition.grams else "portion n/a"
    emit(
        f"logged: {description}  {nutrition.kcal:g} kcal  "
        f"({macro_str})  [{nutrition.source}, {portion_str}]",
    )
    # Publish straight away rather than waiting for a periodic tick: until this
    # lands, the phone still believes this slot is unlogged and will nag for it.
    reason = publish_after_log()
    if reason is not None:
        emit(f"logged locally, not yet published ({reason}).")
    print_summary()
    return 0
