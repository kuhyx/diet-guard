"""The gate's Body tab: calorie goal, weight/body-fat logs + graph, BMI.

A self-contained component, not another link in ``MealGate``'s class chain:
that chain sits at pylint's max-parents cap (see the ``_gatelock_calendar``
notes), and the tab shares no state with the meal form. ``_build_tabs``
constructs one :class:`BodyTab` per monitor; it keeps itself alive through
the Tk callbacks it registers.

Everything shown is informational -- no button here writes the budget. Saving
a weight, body fat, the profile or the goal writes the Body document
(and ``w``, when the weight is the newest), then publishes on a background
thread so a slow network can never freeze a lock screen.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from gatelock import ScrollableSurface

from diet_guard._body_fat_store import MAX_BODY_FAT, MIN_BODY_FAT, set_body_fat
from diet_guard._body_prefs import saved_goal, set_goal
from diet_guard._body_report import (
    activity_lines,
    bmi_lines,
    bmr_lines,
    bodyfat_lines,
    ideal_lines,
    plan_lines,
    profile_lines,
    target_lines,
)
from diet_guard._body_store import (
    MAX_KG,
    MIN_KG,
    newest_weight,
    set_profile,
    set_weight,
)
from diet_guard._body_view import BodyView, budget_or_default, build_view
from diet_guard._daystatus import day_total_kcal
from diet_guard._gatelock_body_graph import GraphBox, draw_weight_graph, in_range
from diet_guard._gatelock_body_input import (
    HEIGHT_CM,
    goal_choice,
    load_goal,
    parse_day,
    parse_float,
)
from diet_guard._gatelock_body_vars import BodyCallbacks, BodyVars
from diet_guard._gatelock_body_widgets import GRAPH_H, GRAPH_W, build_body_frame
from diet_guard._gatelock_calendar_types import _COLORS
from diet_guard._phone_weight import update_weight
from diet_guard._state import load_log, now_local
from diet_guard._sync_events import publish_after_log_detached
from diet_guard._week_plan import plan_week

if TYPE_CHECKING:
    from datetime import date
    import tkinter as tk

    from diet_guard._week_plan import WeekPlan

__all__ = ["BodyTab"]

_DAY_HINT = "Type the YYYY-MM-DD day to delete."


class BodyTab:
    """One monitor's Body tab."""

    def __init__(self, notebook: tk.Misc) -> None:
        """Build the tab into ``notebook`` and render it once."""
        self._budget = budget_or_default()
        self._days: int | None = 90
        self._goal = saved_goal()
        self.vars = BodyVars()
        callbacks = BodyCallbacks(
            save_profile=self.save_profile,
            save_weight=self.save_weight,
            delete_weight=self.delete_weight,
            save_body_fat=self.save_body_fat,
            delete_body_fat=self.delete_body_fat,
            goal_changed=self.goal_changed,
            set_range=self.set_range,
            recalc=self.refresh,
        )
        view = build_view(now_local().date())
        surface = ScrollableSurface(notebook, _COLORS)
        widgets = build_body_frame(
            surface.content,
            self.vars,
            callbacks,
            profile_first=not view.profile.complete,
        )
        widgets.frame.pack(fill="both", expand=True)
        surface.finalize()
        self.container = surface.container
        self._canvas = widgets.canvas
        self._load_inputs(view)
        self.refresh()

    def _load_inputs(self, view: BodyView) -> None:
        """Seed the input fields and table choice from what is stored."""
        prof, logs = self.vars.profile, self.vars.logs
        prof.birth.set(view.profile.birth or "")
        height = view.profile.height_cm
        prof.height.set(f"{height:g}" if height else "")
        prof.sex.set(view.profile.sex or "")
        today = now_local().date().isoformat()
        logs.weight_day.set(today)
        logs.fat_day.set(today)
        self.vars.plan.target.set(str(self._budget))
        load_goal(self.vars.goal, self._goal)

    def refresh(self) -> None:
        """Recompute every block and redraw the graph from local state."""
        today = now_local().date()
        view = build_view(today, self._goal)
        target = None if view.numbers is None else view.numbers.target
        kcal = None if target is None else target.kcal
        self.vars.goal.answer.set("" if kcal is None else f"eat {kcal} kcal")
        lines = target_lines(view)
        texts = {
            "summary": profile_lines(view, today),
            "table": lines[1:] if kcal is not None else lines,
            "bodyfat": bodyfat_lines(view),
            "bmi": bmi_lines(view),
            "ideal": ideal_lines(view),
            "bmr": bmr_lines(view),
            "workouts": activity_lines(view),
            "plan": plan_lines(self._plan(today)),
        }
        for name, lines in texts.items():
            self.vars.blocks[name].set("\n".join(lines))
        self._draw(view, today)

    def _plan(self, today: date) -> WeekPlan:
        log = load_log()
        typed = {
            index: int(value)
            for index, var in enumerate(self.vars.plan.days)
            if (value := parse_float(var.get())) is not None
        }
        target = parse_float(self.vars.plan.target.get())
        return plan_week(
            today,
            int(target) if target else self._budget,
            {day: day_total_kcal(log, day) for day in log},
            typed,
        )

    def _draw(self, view: BodyView, today: date) -> None:
        fat = self.vars.logs.graph.get() == "fat"
        values = view.body_fats if fat else view.weights
        healthy = None if fat or view.numbers is None else view.numbers.healthy
        box = GraphBox(GRAPH_W, GRAPH_H)
        draw_weight_graph(
            self._canvas, in_range(values, today, self._days), box, healthy
        )

    def set_range(self, days: int | None) -> None:
        """Show the last ``days`` days of the graph (None = all)."""
        self._days = days
        self.refresh()

    def _saved(self, message: str) -> None:
        self.vars.status.set(message)
        publish_after_log_detached(
            lambda why: self.vars.status.set(f"Saved; not yet synced ({why}).")
        )
        self.refresh()

    def goal_changed(self) -> None:
        """Re-answer and remember (synced) the goal the pickers now show."""
        self._goal = goal_choice(self.vars.goal, self._goal)
        load_goal(self.vars.goal, self._goal)
        set_goal(self._goal)
        self._saved("Goal saved.")

    def save_profile(self) -> None:
        """Validate and store birth date, height and sex."""
        prof = self.vars.profile
        birth, height = parse_day(prof.birth.get()), parse_float(prof.height.get())
        sex = prof.sex.get()
        if (
            birth is None
            or height is None
            or not HEIGHT_CM[0] <= height <= HEIGHT_CM[1]
            or sex not in {"m", "f"}
        ):
            self.vars.status.set("Profile needs a YYYY-MM-DD birth date, cm and sex.")
            return
        set_profile(birth=birth, height_cm=height, sex=sex)
        self._saved("Profile saved -- it moves to the bottom next time.")

    def save_weight(self) -> None:
        """Validate and store the typed weigh-in."""
        kg = parse_float(self.vars.logs.weight.get())
        day = parse_day(self.vars.logs.weight_day.get())
        if kg is None or day is None or not MIN_KG <= kg <= MAX_KG:
            self.vars.status.set(f"Weight needs {MIN_KG:g}-{MAX_KG:g} kg and a day.")
            return
        self._store_weight(day, kg)
        self._saved(f"Saved {kg:g} kg for {day}.")

    def delete_weight(self) -> None:
        """Delete the weigh-in for the typed day."""
        day = parse_day(self.vars.logs.weight_day.get())
        if day is None:
            self.vars.status.set(_DAY_HINT)
            return
        self._store_weight(day, None)
        self._saved(f"Deleted the weigh-in for {day}.")

    @staticmethod
    def _store_weight(day: str, kg: float | None) -> None:
        set_weight(day, kg)
        newest = newest_weight()
        if newest is not None and day >= newest[0]:
            update_weight(newest[1])

    def save_body_fat(self) -> None:
        """Validate and store the typed body-fat reading."""
        pct = parse_float(self.vars.logs.body_fat.get())
        day = parse_day(self.vars.logs.fat_day.get())
        if pct is None or day is None or not MIN_BODY_FAT <= pct <= MAX_BODY_FAT:
            limits = f"{MIN_BODY_FAT:g}-{MAX_BODY_FAT:g}%"
            self.vars.status.set(f"Body fat needs {limits} and a day.")
            return
        set_body_fat(day, pct)
        self._saved(f"Saved {pct:g}% body fat for {day}.")

    def delete_body_fat(self) -> None:
        """Delete the body-fat reading for the typed day."""
        day = parse_day(self.vars.logs.fat_day.get())
        if day is None:
            self.vars.status.set(_DAY_HINT)
            return
        set_body_fat(day, None)
        self._saved(f"Deleted the body-fat reading for {day}.")
