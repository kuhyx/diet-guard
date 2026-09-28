"""The Body tab's variables and callback bundle.

Split from :mod:`diet_guard._gatelock_body_widgets` for the 250-line cap, and
grouped into small bundles (profile, logs, goal, plan) rather than one flat
record, so each stays under pylint's instance-attribute limit.

.. note::
   Creates ``tkinter`` variables, so it **must** appear in
   ``diet_guard.tests._gate_fixtures._GATE_TK_MODULES``.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import tkinter as tk
from typing import TYPE_CHECKING

from diet_guard._week_plan import WEEKDAYS

if TYPE_CHECKING:
    from collections.abc import Callable

__all__ = [
    "BLOCKS",
    "BodyCallbacks",
    "BodyVars",
    "BodyWidgets",
]

# The read-only text panels, each a monospace block the controller fills.
BLOCKS: tuple[str, ...] = (
    "summary",
    "table",
    "bodyfat",
    "bmi",
    "ideal",
    "bmr",
    "workouts",
    "plan",
)


def _var(value: str = "") -> tk.StringVar:
    return tk.StringVar(value=value)


@dataclass
class ProfileVars:
    """Birth date, height and sex inputs."""

    birth: tk.StringVar = field(default_factory=_var)
    height: tk.StringVar = field(default_factory=_var)
    sex: tk.StringVar = field(default_factory=_var)


@dataclass
class LogVars:
    """The weight and body-fat inputs, and which one the graph shows."""

    weight: tk.StringVar = field(default_factory=_var)
    weight_day: tk.StringVar = field(default_factory=_var)
    body_fat: tk.StringVar = field(default_factory=_var)
    fat_day: tk.StringVar = field(default_factory=_var)
    graph: tk.StringVar = field(default_factory=lambda: _var("weight"))


@dataclass
class GoalVars:
    """The goal sentence's five choices (activity holds its menu label)."""

    direction: tk.StringVar = field(default_factory=_var)
    amount: tk.StringVar = field(default_factory=_var)
    weight_unit: tk.StringVar = field(default_factory=_var)
    time_unit: tk.StringVar = field(default_factory=_var)
    activity: tk.StringVar = field(default_factory=_var)
    answer: tk.StringVar = field(default_factory=_var)


@dataclass
class PlanVars:
    """The week planner's target and per-day overrides."""

    target: tk.StringVar = field(default_factory=_var)
    days: tuple[tk.StringVar, ...] = field(
        default_factory=lambda: tuple(_var() for _ in WEEKDAYS)
    )


@dataclass
class BodyVars:
    """Every input bundle, the status line and the text panels."""

    profile: ProfileVars = field(default_factory=ProfileVars)
    logs: LogVars = field(default_factory=LogVars)
    goal: GoalVars = field(default_factory=GoalVars)
    plan: PlanVars = field(default_factory=PlanVars)
    status: tk.StringVar = field(default_factory=_var)
    blocks: dict[str, tk.StringVar] = field(
        default_factory=lambda: {name: _var() for name in BLOCKS}
    )


@dataclass(frozen=True)
class BodyCallbacks:
    """What the tab's buttons do."""

    save_profile: Callable[[], None]
    save_weight: Callable[[], None]
    delete_weight: Callable[[], None]
    save_body_fat: Callable[[], None]
    delete_body_fat: Callable[[], None]
    goal_changed: Callable[[], None]
    set_range: Callable[[int | None], None]
    recalc: Callable[[], None]


@dataclass(frozen=True)
class BodyWidgets:
    """The widgets the controller touches after building."""

    frame: tk.Frame
    canvas: tk.Canvas
