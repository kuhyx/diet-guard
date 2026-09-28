"""Daily steps from the phone's Health Connect, turned into exercise kcal.

The **phone** writes these (it holds the Health Connect permission): one
count per day of steps taken *outside* every published workout's
``start..end`` window, so a recorded walk is never counted as both a workout
and steps. Every device reads them.

Only steps above :data:`STEP_BASELINE` count: the ``BMR x 1.2`` sedentary
baseline the measured TDEE starts from already assumes a few thousand steps
of ordinary daily movement. The rest are walking at the per-km rate
(``_activity_kcal``: 0.5 kcal per kg per km, net of resting), over a stride
estimated from height.

KEEP IN SYNC WITH ``app/lib/services/body_steps.dart``.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from diet_guard._body_store import as_number, is_day, read_body

if TYPE_CHECKING:
    from diet_guard._budget_biometrics import Biometrics

__all__ = ["STEP_BASELINE", "daily_steps", "step_kcal", "stride_m"]

STEP_BASELINE = 4000
# Stride as a fraction of height (the common pedometer estimate).
_STRIDE_MALE = 0.415
_STRIDE_FEMALE = 0.413
_WALK_KCAL_PER_KG_KM = 0.5
_M_PER_KM = 1000.0


def daily_steps() -> dict[str, int]:
    """``YYYY-MM-DD`` -> steps outside workouts, oldest first."""
    log = read_body()["steps"]
    counts = {
        day: as_number(cell.get("n")) if isinstance(cell, dict) else None
        for day, cell in log.items()
    }
    return {
        day: int(n)
        for day, n in sorted(counts.items())
        if n is not None and is_day(day)
    }


def stride_m(bio: Biometrics) -> float:
    """Estimated walking stride in metres."""
    return bio.height_cm / 100.0 * (_STRIDE_MALE if bio.is_male else _STRIDE_FEMALE)


def step_kcal(steps: int, bio: Biometrics) -> float:
    """Net kcal of the steps above the baseline, as walking."""
    extra = max(0, steps - STEP_BASELINE)
    km = extra * stride_m(bio) / _M_PER_KM
    return km * _WALK_KCAL_PER_KG_KM * bio.weight_kg
