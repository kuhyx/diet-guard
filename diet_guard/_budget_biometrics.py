"""Biometrics and the one-time budget computation seeded from them.

Split out of :mod:`._budget` to keep both files under the repo's 250-line
limit.  This half is pure arithmetic -- Mifflin-St Jeor BMR, the activity and
goal multipliers -- and touches no file, which is why ``BUDGET_FILE`` stays
named by :mod:`._budget` alone.

The biometrics themselves are used once and discarded: only the computed
budget is ever persisted.
"""

from __future__ import annotations

from dataclasses import dataclass

# The floor a computed target can never go below, however aggressive the
# deficit. Defined here with the computation it guards rather than imported
# from _budget, which would make the dependency circular.
_MIN_SANE_BUDGET = 1200

__all__ = ["Biometrics", "compute_target_budget", "mifflin_st_jeor_bmr"]


@dataclass(frozen=True)
class Biometrics:
    """Body metrics that feed the Mifflin-St Jeor budget formula.

    Grouped into one value object so the budget calculation stays under the
    repo's five-argument lint ceiling and so the inputs travel together.

    Attributes:
        weight_kg: Body mass in kilograms.
        height_cm: Height in centimetres.
        age_years: Age in years.
        is_male: True for the male BMR constant (+5), False for female (-161).
    """

    weight_kg: float
    height_cm: float
    age_years: float
    is_male: bool


def mifflin_st_jeor_bmr(bio: Biometrics) -> float:
    """Return resting metabolic rate via the Mifflin-St Jeor equation.

    Args:
        bio: The person's body metrics.

    Returns:
        Basal metabolic rate in kcal/day.
    """
    base = 10.0 * bio.weight_kg + 6.25 * bio.height_cm - 5.0 * bio.age_years
    return base + 5.0 if bio.is_male else base - 161.0


def compute_target_budget(
    bio: Biometrics,
    *,
    activity_factor: float,
    deficit_kcal: float,
) -> int:
    """Return the daily kcal target: TDEE minus a deficit, floored for safety.

    TDEE (total daily energy expenditure) is the BMR scaled by an activity
    factor; subtracting a deficit yields a target that drives gradual loss.

    Args:
        bio: The person's body metrics.
        activity_factor: Multiplier for daily activity (e.g. 1.2 sedentary,
            1.375 light, 1.55 moderate, 1.725 very active).
        deficit_kcal: Calories subtracted from TDEE for weight loss.

    Returns:
        The target budget in kcal, never below ``_MIN_SANE_BUDGET``.
    """
    bmr = mifflin_st_jeor_bmr(bio)
    tdee = bmr * activity_factor
    target = round(tdee - deficit_kcal)
    return max(target, _MIN_SANE_BUDGET)
