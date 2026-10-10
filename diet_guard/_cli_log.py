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
import threading
from typing import TYPE_CHECKING

from diet_guard._foodbank import remember_food
from diet_guard._kuchnia_import import refresh_delivery_once
from diet_guard._meal_schedule_store import current_schedule
from diet_guard._portions import DEFAULT_ITEM_GRAMS, estimate_unit_grams
from diet_guard._resolve import ManualMacros, resolve_nutrition
from diet_guard._slot_wire import parse_hhmm
from diet_guard._slots import resolve_future_when, slot_for_log, slot_label
from diet_guard._state import log_meal, now_local
from diet_guard._sync_events import publish_after_log_detached

if TYPE_CHECKING:
    from collections.abc import Callable
    from datetime import datetime

    from diet_guard._meal_schedule import MealSchedule


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
    """How much was eaten, when, and the basis for any typed macros.

    Grouped so :func:`cmd_ate` stays within the argument-count limit.

    Attributes:
        grams: Explicit grams eaten, or None.
        count: Number of items eaten (an alternative to ``grams``), or None.
        per_grams: Reference weight the typed macros are stated for (e.g. 100
            for a per-100 g label), or None to treat the macros as totals.
        date: Log against this future date (``YYYY-MM-DD``) instead of now.
            Must be given together with ``hour``. None means "now".
        hour: The slot on ``date`` this meal satisfies, as the user typed it
            (``HH:MM`` or ``HH``; parsed by
            :func:`diet_guard._slot_wire.parse_hhmm`). Required together with
            ``date``.
    """

    grams: float | None
    count: float | None
    per_grams: float | None
    date: str | None = None
    hour: str | None = None


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
                (
                    f"(assumed {DEFAULT_ITEM_GRAMS:g} g per item; "
                    "pass --grams to be exact)"
                ),
            )
        return portion.count * unit, None
    return portion.grams, None


def _resolve_target(
    portion: Portion, schedule: MealSchedule
) -> tuple[datetime | None, int]:
    """Resolve ``(when, slot)`` for ``portion``: now, or a future pre-log.

    Split out of :func:`cmd_ate` to keep it under pylint's local-variable
    limit.

    Raises:
        ValueError: ``portion.hour`` is not a clock time, or
            ``portion.date``/``portion.hour`` are an invalid future
            combination -- see :func:`diet_guard._slots.resolve_future_when`.
    """
    if portion.date is None or portion.hour is None:
        return None, slot_for_log(now_local(), schedule)
    slot = parse_hhmm(portion.hour)
    when = resolve_future_when(portion.date, slot, schedule, now_local())
    return when, slot


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

    Passing ``--date``/``--hour`` (both required together) pre-logs the meal
    against a future date+slot instead of now; see
    :func:`diet_guard._slots.resolve_future_when`.

    Args:
        emit: A one-line output sink (``_cli._emit``, passed in rather than
            imported -- see ``_cli_sync.cmd_sync`` for why).
        print_summary: Prints today's total and remaining budget.
        description: The food as the user typed it.
        portion: How much was eaten, and optionally when.
        macros: Any manually supplied calories/macros.

    Returns:
        0 once logged, or 1 when the food could not be resolved, or the
        date/hour were missing/invalid.
    """
    if (portion.date is None) != (portion.hour is None):
        emit("--date and --hour must be given together.")
        return 1
    try:
        when, slot = _resolve_target(portion, current_schedule())
    except ValueError as exc:
        emit(str(exc))
        return 1
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
    log_meal(description, nutrition, slot, when=when)
    remember_food(description, nutrition)
    macro_str = f"P{nutrition.protein_g:g} C{nutrition.carbs_g:g} F{nutrition.fat_g:g}"
    portion_str = f"{nutrition.grams:g} g" if nutrition.grams else "portion n/a"
    emit(
        f"logged: {description}  {nutrition.kcal:g} kcal  "
        f"({macro_str})  [{nutrition.source}, {portion_str}]"
        f"{f' for {portion.date} {slot_label(slot)}' if when else ''}",
    )
    # Publish straight away rather than waiting for a periodic tick: until this
    # lands, the phone still believes this slot is unlogged and will nag for it.
    #
    # On a background thread, though: the full tick measures ~15.5s and this is
    # an interactive command, so blocking the terminal on it after every meal
    # is the whole complaint. The local write above is already durable, so the
    # worst case is a late publish -- the trade `_sync_events` documents. The
    # thread is non-daemon, so the process waits for the push at exit even
    # though the user already has their output.
    publish_after_log_detached(
        lambda reason: emit(f"logged locally, not yet published ({reason})."),
    )
    # Warm the catering bank on the same background thread, so tomorrow's
    # autocomplete already knows today's dishes. Guarded to one fetch per day
    # (`refresh_delivery_once`), because this fires after *every* meal and each
    # unguarded refresh is a login plus a three-request walk. Never inline: it
    # would add up to the whole catering deadline to an interactive command.
    _warm_catering_bank_detached()
    print_summary()
    return 0


def _warm_catering_bank_detached() -> None:
    """Refresh today's catering bank off-thread, ignoring any failure.

    Non-daemon, matching ``publish_after_log_detached``: the process waits for
    it at exit while the user already has their output. Failures are silent by
    design -- the user asked to log a meal, not to hear about the caterer.
    """

    def _warm() -> None:
        # A module-global lookup, so the conftest patch on this module's
        # attribute takes effect -- and so ruff can see the import is used.
        refresh_delivery_once(now_local().date())

    threading.Thread(target=_warm, daemon=False).start()
