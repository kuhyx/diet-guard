"""The calorie goal the user last picked -- remembered and synced.

Stored as one extra field, ``goal``, on the synced ``profile`` record, so the
sentence "To lose 0.5 kg / week on Moderate eat ..." reads the same on the PC
gate and the phone. Each part is validated on read: an unknown direction,
unit or activity (a peer on a newer version, a typo) falls back to that part
of :data:`~diet_guard._body_energy.DEFAULT_GOAL` rather than breaking the tab.

KEEP IN SYNC WITH ``app/lib/services/body_prefs.dart``.
"""

from __future__ import annotations

from dataclasses import replace

from diet_guard._body_energy import (
    ACTIVITY_CHOICES,
    DEFAULT_GOAL,
    DIRECTIONS,
    TIME_UNITS,
    WEIGHT_UNITS,
    Goal,
)
from diet_guard._body_store import as_number, read_body, set_profile

__all__ = ["GOAL_FIELD", "goal_from_json", "goal_to_json", "saved_goal", "set_goal"]

GOAL_FIELD = "goal"


def goal_to_json(goal: Goal) -> dict[str, object]:
    """The wire/disk form (short keys)."""
    return {
        "dir": goal.direction,
        "amt": goal.amount,
        "wu": goal.weight_unit,
        "tu": goal.time_unit,
        "act": goal.activity,
    }


def goal_from_json(raw: object) -> Goal:
    """Parse a stored goal part by part, defaulting whatever is unusable."""
    if not isinstance(raw, dict):
        return DEFAULT_GOAL
    amount = as_number(raw.get("amt"))
    goal = DEFAULT_GOAL
    if raw.get("dir") in DIRECTIONS:
        goal = replace(goal, direction=str(raw["dir"]))
    if amount is not None and amount >= 0:
        goal = replace(goal, amount=amount)
    if raw.get("wu") in WEIGHT_UNITS:
        goal = replace(goal, weight_unit=str(raw["wu"]))
    if raw.get("tu") in TIME_UNITS:
        goal = replace(goal, time_unit=str(raw["tu"]))
    if raw.get("act") in ACTIVITY_CHOICES:
        goal = replace(goal, activity=str(raw["act"]))
    return goal


def saved_goal() -> Goal:
    """The remembered goal (the default until one is saved)."""
    cell = read_body()["profile"].get(GOAL_FIELD)
    return goal_from_json(cell.get("v") if isinstance(cell, dict) else None)


def set_goal(goal: Goal) -> None:
    """Remember (and sync) ``goal``."""
    set_profile(**{GOAL_FIELD: goal_to_json(goal)})
