"""The daily calorie target for one chosen goal -- the Body tab's top line.

"To **lose** **0.5** **kg** / **week** on **Moderate** eat **2019** kcal":
every bold word is a choice (:class:`Goal`), remembered and synced
(``_body_prefs``). Informational only: nothing here writes the budget.

TDEE is the table BMR (Mifflin-St Jeor, or Katch-McArdle once a body-fat % is
logged -- ``_body_calc.table_bmr``) times an activity factor, or for a
"Measured" choice ``BMR x 1.2`` plus the real mean daily exercise from
:func:`diet_guard._activity_kcal.daily_exercise` by that formula. The target
is ``TDEE -/+ (amount in kg per day) x 7700``. A target below the 1200 kcal
floor is reported and flagged, never clamped.

Mirrored in ``app/lib/services/body_energy.dart``; gated by the shared
``tests/fixtures/body_calc.json``.
"""

from __future__ import annotations

from dataclasses import dataclass

from diet_guard._activity_kcal import FORMULAS
from diet_guard._body_calc import half_up
from diet_guard._budget_biometrics import _MIN_SANE_BUDGET

__all__ = [
    "ACTIVITY_CHOICES",
    "ACTIVITY_LEVELS",
    "DEFAULT_GOAL",
    "DIRECTIONS",
    "KCAL_PER_KG",
    "MEASURED_PREFIX",
    "MIN_TARGET_KCAL",
    "PRESET_AMOUNTS",
    "TIME_UNITS",
    "WEIGHT_UNITS",
    "ActivityLevel",
    "Goal",
    "Target",
    "activity_label",
    "goal_target",
]

KCAL_PER_KG = 7700.0
MIN_TARGET_KCAL = _MIN_SANE_BUDGET
_SEDENTARY = 1.2
# A "Measured" choice is ``measured:<formula>`` (MET, ACSM, Per-km).
MEASURED_PREFIX = "measured:"

DIRECTIONS: tuple[str, ...] = ("lose", "maintain", "gain")
# Offered in the amount picker; any other typed number is accepted too.
PRESET_AMOUNTS: tuple[float, ...] = (0.25, 0.5, 0.75, 1.0)
# Kilograms per unit.
WEIGHT_UNITS: dict[str, float] = {
    "kg": 1.0,
    "lb": 0.45359237,
    "g": 0.001,
    "st": 6.35029318,
}
# Days per unit; a month is the mean Gregorian month.
TIME_UNITS: dict[str, float] = {
    "day": 1.0,
    "week": 7.0,
    "month": 30.436875,
    "year": 365.2425,
}


@dataclass(frozen=True)
class ActivityLevel:
    """One selectable activity level and its TDEE multiplier."""

    key: str
    label: str
    factor: float
    meaning: str


ACTIVITY_LEVELS: tuple[ActivityLevel, ...] = (
    ActivityLevel("sedentary", "Sedentary", 1.2, "little or no exercise"),
    ActivityLevel("light", "Light", 1.375, "exercise 1-3x a week"),
    ActivityLevel("moderate", "Moderate", 1.55, "exercise 3-5x a week"),
    ActivityLevel("very", "Very active", 1.725, "exercise 6-7x a week"),
    ActivityLevel("extra", "Extra active", 1.9, "training twice a day"),
)
# Every activity choice, in menu order: the five levels, then measured.
ACTIVITY_CHOICES: tuple[str, ...] = (
    *(lvl.key for lvl in ACTIVITY_LEVELS),
    *(f"{MEASURED_PREFIX}{name}" for name in FORMULAS),
)


@dataclass(frozen=True)
class Goal:
    """What the user wants: direction, amount per time, at an activity."""

    direction: str
    amount: float
    weight_unit: str
    time_unit: str
    activity: str

    def kg_per_day(self) -> float:
        """Signed change in kg/day: positive loses, negative gains."""
        if self.direction == "maintain":
            return 0.0
        rate = self.amount * WEIGHT_UNITS[self.weight_unit] / TIME_UNITS[self.time_unit]
        return rate if self.direction == "lose" else -rate


DEFAULT_GOAL = Goal("lose", 0.5, "kg", "week", "moderate")


@dataclass(frozen=True)
class Target:
    """The answer to a :class:`Goal`, or why there is none.

    Attributes:
        kcal: Daily target, or None when the goal needs measured activity
            that has not been published yet.
        tdee: The maintenance figure it was derived from, when known.
        bmr_name: The resting-burn formula the TDEE scales.
    """

    kcal: int | None
    tdee: float | None
    bmr_name: str

    @property
    def below_floor(self) -> bool:
        """Whether the target is under the 1200 kcal floor."""
        return self.kcal is not None and self.kcal < MIN_TARGET_KCAL


def activity_label(key: str) -> str:
    """Menu text for an activity choice, e.g. ``Measured (ACSM)``."""
    if key.startswith(MEASURED_PREFIX):
        return f"Measured ({key[len(MEASURED_PREFIX) :]})"
    for lvl in ACTIVITY_LEVELS:
        if lvl.key == key:
            return lvl.label
    return key


def _tdee(bmr: float, activity: str, exercise: dict[str, float] | None) -> float | None:
    """Maintenance kcal for ``activity``; None for measured without data."""
    if activity.startswith(MEASURED_PREFIX):
        formula = activity[len(MEASURED_PREFIX) :]
        if exercise is None or formula not in exercise:
            return None
        return bmr * _SEDENTARY + exercise[formula]
    factor = next((lvl.factor for lvl in ACTIVITY_LEVELS if lvl.key == activity), None)
    return None if factor is None else bmr * factor


def goal_target(
    goal: Goal, bmr: float, bmr_name: str, exercise: dict[str, float] | None
) -> Target:
    """The daily kcal that meets ``goal`` from a ``bmr`` (kcal/day)."""
    tdee = _tdee(bmr, goal.activity, exercise)
    if tdee is None:
        return Target(kcal=None, tdee=None, bmr_name=bmr_name)
    kcal = int(half_up(tdee - goal.kg_per_day() * KCAL_PER_KG))
    return Target(kcal=kcal, tdee=tdee, bmr_name=bmr_name)
