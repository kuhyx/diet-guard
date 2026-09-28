"""Everything the Body surfaces show, gathered once from local state.

The CLI's ``body`` command and the gate's Body tab both render a
:class:`BodyView`; neither reads the store or runs a formula itself, so the
two cannot drift. Local reads only -- no network -- because the gate builds
this on the Tk thread.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta
from typing import TYPE_CHECKING

from diet_guard._activity_kcal import daily_exercise, window_days
from diet_guard._body_activity_store import activity
from diet_guard._body_calc import (
    bmi_report,
    bmr_formulas,
    healthy_range,
    ideal_summary,
    ideal_weights,
    table_bmr,
)
from diet_guard._body_energy import goal_target
from diet_guard._body_fat_store import body_fats
from diet_guard._body_prefs import saved_goal
from diet_guard._body_steps import daily_steps, step_kcal
from diet_guard._body_store import profile, weights
from diet_guard._budget import (
    BudgetFileCorruptError,
    BudgetNotInitializedError,
    daily_budget,
)

if TYPE_CHECKING:
    from datetime import date

    from diet_guard._activity_kcal import Session
    from diet_guard._body_calc import BmiReport, Formula
    from diet_guard._body_energy import Goal, Target
    from diet_guard._body_store import Profile
    from diet_guard._budget_biometrics import Biometrics


# The app-wide unset-budget default (the gate's History tab and the phone use
# the same 2200), so the week planner has a target from a fresh install.
DEFAULT_TARGET_KCAL = 2200


def budget_or_default() -> int:
    """Today's budget, or :data:`DEFAULT_TARGET_KCAL` when unset or corrupt."""
    try:
        return daily_budget()
    except BudgetNotInitializedError, BudgetFileCorruptError:
        return DEFAULT_TARGET_KCAL


@dataclass(frozen=True)
class BodyNumbers:
    """The formula outputs, present only when profile and weight both exist."""

    bio: Biometrics
    bmi: BmiReport
    ideal: tuple[Formula, ...]
    ideal_summary: tuple[float, float, float] | None
    healthy: tuple[float, float]
    bmr: tuple[Formula, ...]
    target: Target


@dataclass(frozen=True)
class ExerciseSummary:
    """Measured daily exercise over the averaging window.

    Attributes:
        means: Mean daily net kcal per formula, steps included.
        steps_kcal: The counted steps' share of each mean (same window).
        days: Full past days averaged over (1-14; see ``window_days``).
    """

    means: dict[str, float]
    steps_kcal: float
    days: int


@dataclass(frozen=True)
class BodyView:
    """The Body tab's whole state.

    Attributes:
        profile: Stored profile (fields may be unset).
        goal: The calorie goal the target line answers.
        weights: Live weight log, oldest first.
        body_fats: Live body-fat log (%), oldest first.
        steps: Phone-published steps outside workouts, per day.
        sessions: Published workouts (empty when none).
        activity_stamp: When the workouts were published, or None.
        exercise: Measured exercise, or None without published activity or
            steps, or without a profile to scale them by.
        numbers: The formulas, or None while profile/weight are missing.
    """

    profile: Profile
    goal: Goal
    weights: dict[str, float]
    body_fats: dict[str, float]
    steps: dict[str, int]
    sessions: tuple[Session, ...]
    activity_stamp: str | None
    exercise: ExerciseSummary | None
    numbers: BodyNumbers | None

    @property
    def weight(self) -> float | None:
        """The newest logged weight, or None."""
        return self.weights[max(self.weights)] if self.weights else None


def _numbers(
    bio: Biometrics, fat: float | None, goal: Goal, exercise: ExerciseSummary | None
) -> BodyNumbers:
    """Every formula for one person."""
    bmr = table_bmr(bio, fat)
    ideal = ideal_weights(bio)
    means = None if exercise is None else exercise.means
    return BodyNumbers(
        bio=bio,
        bmi=bmi_report(bio),
        ideal=ideal,
        ideal_summary=ideal_summary(ideal),
        healthy=healthy_range(bio),
        bmr=bmr_formulas(bio, fat),
        target=goal_target(goal, bmr.value or 0.0, bmr.name, means),
    )


def _exercise(
    bio: Biometrics, sessions: tuple[Session, ...], steps: dict[str, int], today: date
) -> ExerciseSummary:
    """Averages over one shared window, so the steps share adds up."""
    by_day = {day: step_kcal(n, bio) for day, n in steps.items()}
    days = window_days(sessions, today, by_day)
    first = (today - timedelta(days=days)).isoformat()
    in_window = sum(k for d, k in by_day.items() if first <= d < today.isoformat())
    return ExerciseSummary(
        means=daily_exercise(sessions, bio.weight_kg, today, by_day),
        steps_kcal=in_window / days if days else 0.0,
        days=days,
    )


def build_view(today: date, goal: Goal | None = None) -> BodyView:
    """Read the store and evaluate every formula for ``today``.

    Args:
        today: The local date (ages and the exercise window hang off it).
        goal: The calorie goal; None reads the saved one.
    """
    chosen = saved_goal() if goal is None else goal
    log = weights()
    fats = body_fats()
    steps = daily_steps()
    sessions, stamp = activity()
    weight = log[max(log)] if log else None
    bio = profile().biometrics(weight, today) if weight is not None else None
    exercise = (
        _exercise(bio, sessions, steps, today)
        if bio is not None and (stamp is not None or steps)
        else None
    )
    return BodyView(
        profile=profile(),
        goal=chosen,
        weights=log,
        body_fats=fats,
        steps=steps,
        sessions=sessions,
        activity_stamp=stamp,
        exercise=exercise,
        numbers=(
            None
            if bio is None
            else _numbers(bio, fats[max(fats)] if fats else None, chosen, exercise)
        ),
    )
