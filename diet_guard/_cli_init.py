"""CLI handler for the ``init`` subcommand.

Split out of :mod:`diet_guard._cli` to hold the repo's 250-line cap, following
the same thin-per-subcommand-handler shape as ``_cli_gate.py`` (``gate``),
``_cli_log.py`` (``ate``) and ``_cli_sync.py`` (``sync``).

The biometrics prompted for here seed the Body profile too (height, sex, a
birth date estimated from the typed age, and today's weigh-in), so BMI and
ideal weight work straight after ``init``. Refine the birth date with
``diet_guard profile --birth``. See ``docs/DOCS-body.md``.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from diet_guard._body_store import set_profile, set_weight
from diet_guard._budget import write_budget
from diet_guard._budget_biometrics import Biometrics, compute_target_budget
from diet_guard._state import now_local

if TYPE_CHECKING:
    from collections.abc import Callable

# Accepted answers for the sex prompt that map to the male BMR constant.
MALE_ANSWERS = {"m", "male"}
FEMALE_ANSWERS = {"f", "female"}


def read_init_inputs(
    emit: Callable[[str], None],
    ask: Callable[[str], str],
) -> tuple[Biometrics, float, float] | None:
    """Prompt for biometrics on stdin; return (bio, activity, deficit) or None.

    Returns None (after printing why) on any unparsable or out-of-range input,
    so a typo never sets a wrong budget.
    """
    try:
        weight = float(ask("weight in kg:"))
        height = float(ask("height in cm:"))
        age = float(ask("age in years:"))
        sex_raw = ask("sex (m/f):").lower()
        activity = float(
            ask(
                "activity factor "
                "(1.2 sedentary / 1.375 light / 1.55 moderate / 1.725 active):",
            ),
        )
        deficit = float(ask("daily deficit in kcal (e.g. 200):"))
    except ValueError:
        emit("that was not a number; nothing was set.")
        return None

    if sex_raw in MALE_ANSWERS:
        is_male = True
    elif sex_raw in FEMALE_ANSWERS:
        is_male = False
    else:
        emit('sex must be "m" or "f"; nothing was set.')
        return None

    bio = Biometrics(
        weight_kg=weight,
        height_cm=height,
        age_years=age,
        is_male=is_male,
    )
    return bio, activity, deficit


def cmd_init(
    emit: Callable[[str], None],
    ask: Callable[[str], str],
) -> int:
    """Compute the starting budget from biometrics and write it."""
    inputs = read_init_inputs(emit, ask)
    if inputs is None:
        return 2
    bio, activity, deficit = inputs
    budget = compute_target_budget(
        bio,
        activity_factor=activity,
        deficit_kcal=deficit,
    )
    write_budget(budget, weight_kg=bio.weight_kg)
    today = now_local().date()
    # Same month/day as today, so the estimated age is exact right now.
    birth = today.replace(year=today.year - int(bio.age_years), day=min(today.day, 28))
    set_profile(
        birth=birth.isoformat(),
        height_cm=bio.height_cm,
        sex="m" if bio.is_male else "f",
    )
    set_weight(today.isoformat(), bio.weight_kg, "init")
    emit(f"budget computed from your biometrics: {budget:g} kcal/day.")
    emit("edit it any time from the gate's calendar tab or the phone app.")
    return 0
