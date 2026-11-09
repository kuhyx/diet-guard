"""Parse and seed the Body tab's inputs -- pure over the tab's variables.

Split from :mod:`diet_guard._gatelock_body` for the 250-line cap. No widget
is built here; the functions only read and write ``StringVar``-likes.
"""

from __future__ import annotations

from datetime import date
from typing import TYPE_CHECKING

from diet_guard._body_prefs import goal_from_json
from diet_guard._gatelock_body_glyphs import ACTIVITY
from diet_guard._gatelock_glyphs import DIRECTION, SPAN

if TYPE_CHECKING:
    from diet_guard._body_energy import Goal
    from diet_guard._gatelock_body_vars import GoalVars

__all__ = ["HEIGHT_CM", "goal_choice", "load_goal", "parse_day", "parse_float"]

# Outside this range (cm) a height is a typo rather than a person.
HEIGHT_CM = (50.0, 260.0)


def parse_float(text: str) -> float | None:
    """``text`` as a float (comma decimals accepted), or None."""
    try:
        return float(text.strip().replace(",", "."))
    except ValueError:
        return None


def parse_day(text: str) -> str | None:
    """``text`` as a normalised ``YYYY-MM-DD``, or None."""
    try:
        return date.fromisoformat(text.strip()).isoformat()
    except ValueError:
        return None


def _back(glyphs: dict[str, str], shown: str, fallback: str) -> str:
    """The stored key whose glyph a picker shows, or ``fallback``."""
    return next((key for key, glyph in glyphs.items() if glyph == shown), fallback)


def load_goal(goal_vars: GoalVars, goal: Goal) -> None:
    """Put ``goal`` into the goal row's pickers, as glyphs (units stay)."""
    goal_vars.direction.set(DIRECTION.get(goal.direction, goal.direction))
    goal_vars.amount.set(f"{goal.amount:g}")
    goal_vars.weight_unit.set(goal.weight_unit)
    goal_vars.time_unit.set(SPAN.get(goal.time_unit, goal.time_unit))
    goal_vars.activity.set(ACTIVITY.get(goal.activity, goal.activity))


def goal_choice(goal_vars: GoalVars, fallback: Goal) -> Goal:
    """The goal the pickers show; an unreadable amount keeps ``fallback``'s."""
    amount = parse_float(goal_vars.amount.get())
    return goal_from_json(
        {
            "dir": _back(DIRECTION, goal_vars.direction.get(), fallback.direction),
            "amt": fallback.amount if amount is None or amount < 0 else amount,
            "wu": goal_vars.weight_unit.get(),
            "tu": _back(SPAN, goal_vars.time_unit.get(), fallback.time_unit),
            "act": _back(ACTIVITY, goal_vars.activity.get(), fallback.activity),
        }
    )
