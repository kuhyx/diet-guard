"""Widget builders for the gate's Body tab.

Split from :mod:`diet_guard._gatelock_body` (the controller) for the 250-line
cap. Everything here only builds and packs; every value lives in
:class:`~diet_guard._gatelock_body_vars.BodyVars` and every action is a
callback.

Layout, top to bottom: the goal sentence ("To lose 0.5 kg / week on
Moderate eat 2019 kcal", every choice a drop-down), then weight with the
graph beside BMI, ideal weight and resting burn, then workouts and the week
plan, then the profile (set up once -- first instead while incomplete) and
last the body-fat log.

.. note::
   Builds ``tkinter`` widgets, so it **must** appear in
   ``diet_guard.tests._gate_fixtures._GATE_TK_MODULES``.
"""

from __future__ import annotations

import tkinter as tk
from typing import TYPE_CHECKING

from gatelock import ButtonStyle, make_button

from diet_guard._body_energy import (
    ACTIVITY_CHOICES,
    DIRECTIONS,
    PRESET_AMOUNTS,
    TIME_UNITS,
    WEIGHT_UNITS,
    activity_label,
)
from diet_guard._gatelock_body_graph import GRAPH_RANGES
from diet_guard._gatelock_body_vars import BodyWidgets
from diet_guard._gatelock_calendar_types import _ACCENT, _COLORS, _FIELD_BG, _MUTED
from diet_guard._gatelock_spacing import MD, SM, XS
from diet_guard._gatelock_typography import BODY, LABEL, SUBTITLE, TITLE
from diet_guard._gatelock_ui import BG, FG
from diet_guard._week_plan import WEEKDAYS

if TYPE_CHECKING:
    from collections.abc import Callable

    from diet_guard._gatelock_body_vars import BodyCallbacks, BodyVars

__all__ = ["GRAPH_H", "GRAPH_W", "build_body_frame"]

GRAPH_W = 720
GRAPH_H = 300
_MONO = ("Courier", LABEL)
_SECONDARY = ButtonStyle(variant="secondary", bold=False)
_TOGGLE = {"bg": BG, "fg": FG, "selectcolor": _FIELD_BG, "activebackground": BG}


def _font(size: int = LABEL) -> tuple[str, int]:
    return (_COLORS.typography.font_family, size)


def _label(parent: tk.Misc, text: str, size: int = LABEL) -> None:
    tk.Label(parent, text=text, font=_font(size), bg=BG, fg=FG).pack(
        side="left", padx=(0, XS)
    )


def _entry(parent: tk.Misc, var: tk.StringVar, width: int, size: int = BODY) -> None:
    tk.Entry(
        parent,
        textvariable=var,
        width=width,
        font=_font(size),
        bg=_FIELD_BG,
        fg=FG,
        insertbackground=FG,
    ).pack(side="left", padx=(0, SM))


def _row(parent: tk.Misc) -> tk.Frame:
    row = tk.Frame(parent, bg=BG)
    row.pack(anchor="w", pady=(XS, XS))
    return row


def _block(parent: tk.Misc, var: tk.StringVar) -> None:
    tk.Label(
        parent, textvariable=var, font=_MONO, bg=BG, fg=FG, justify="left", anchor="w"
    ).pack(anchor="w", pady=(SM, 0))


def _button(parent: tk.Misc, text: str, command: Callable[[], None]) -> None:
    make_button(parent, _COLORS, text, command, _SECONDARY).pack(
        side="left", padx=(0, SM)
    )


def _menu(
    parent: tk.Misc, var: tk.StringVar, values: list[str], cb: BodyCallbacks
) -> None:
    """A drop-down that re-answers the goal whenever a value is picked."""
    menu = tk.OptionMenu(parent, var, *values, command=lambda _v: cb.goal_changed())
    menu.config(font=_font(SUBTITLE), bg=_FIELD_BG, fg=_ACCENT, highlightthickness=0)
    menu.pack(side="left", padx=(0, XS))


def _build_goal(parent: tk.Misc, vars_: BodyVars, cb: BodyCallbacks) -> None:
    """``To [lose] [0.5][v] [kg] / [week] on [Moderate]  eat 2019 kcal``."""
    goal = vars_.goal
    row = _row(parent)
    _label(row, "To", SUBTITLE)
    _menu(row, goal.direction, list(DIRECTIONS), cb)
    _entry(row, goal.amount, 5, SUBTITLE)
    _menu(row, goal.amount, [f"{a:g}" for a in PRESET_AMOUNTS], cb)
    _menu(row, goal.weight_unit, list(WEIGHT_UNITS), cb)
    _label(row, "/", SUBTITLE)
    _menu(row, goal.time_unit, list(TIME_UNITS), cb)
    _label(row, "on", SUBTITLE)
    _menu(row, goal.activity, [activity_label(k) for k in ACTIVITY_CHOICES], cb)
    tk.Label(
        row, textvariable=goal.answer, font=(*_font(TITLE), "bold"), bg=BG, fg=_ACCENT
    ).pack(side="left", padx=(MD, 0))
    _button(row, "Apply typed amount", cb.goal_changed)
    _block(parent, vars_.blocks["table"])


def _build_profile(parent: tk.Misc, vars_: BodyVars, cb: BodyCallbacks) -> None:
    row = _row(parent)
    _label(row, "Profile -- born (YYYY-MM-DD)")
    _entry(row, vars_.profile.birth, 11)
    _label(row, "Height cm")
    _entry(row, vars_.profile.height, 6)
    sex = vars_.profile.sex
    for value, text in (("m", "male"), ("f", "female")):
        tk.Radiobutton(row, text=text, value=value, variable=sex, **_TOGGLE).pack(
            side="left"
        )
    _button(row, "Save profile", cb.save_profile)
    _block(parent, vars_.blocks["summary"])


def _dated_row(
    parent: tk.Misc,
    label: str,
    vars_pair: tuple[tk.StringVar, tk.StringVar],
    actions: tuple[Callable[[], None], Callable[[], None]],
) -> None:
    row = _row(parent)
    _label(row, label)
    _entry(row, vars_pair[0], 6)
    _label(row, "on")
    _entry(row, vars_pair[1], 11)
    _button(row, "Save", actions[0])
    _button(row, "Delete that day", actions[1])


def _build_left(col: tk.Misc, vars_: BodyVars, cb: BodyCallbacks) -> tk.Canvas:
    logs = vars_.logs
    pair = (logs.weight, logs.weight_day)
    _dated_row(col, "Weight kg", pair, (cb.save_weight, cb.delete_weight))
    row = _row(col)
    for value, text in (("weight", "Weight"), ("fat", "Body fat")):
        tk.Radiobutton(
            row,
            text=text,
            value=value,
            variable=logs.graph,
            command=cb.recalc,
            **_TOGGLE,
        ).pack(side="left")
    for text, days in GRAPH_RANGES:
        _button(row, text, lambda d=days: cb.set_range(d))
    canvas = tk.Canvas(col, width=GRAPH_W, height=GRAPH_H, bg=BG, highlightthickness=0)
    canvas.pack(anchor="w", pady=(SM, 0))
    tk.Label(col, textvariable=vars_.status, font=_font(), bg=BG, fg=_MUTED).pack(
        anchor="w"
    )
    _block(col, vars_.blocks["workouts"])
    return canvas


def _build_right(col: tk.Misc, vars_: BodyVars, cb: BodyCallbacks) -> None:
    for name in ("bmi", "ideal", "bmr"):
        _block(col, vars_.blocks[name])
    row = _row(col)
    _label(row, "Week average target kcal")
    _entry(row, vars_.plan.target, 6)
    for name, var in zip(WEEKDAYS, vars_.plan.days, strict=True):
        _label(row, name)
        _entry(row, var, 5)
    _button(row, "Plan week", cb.recalc)
    _block(col, vars_.blocks["plan"])


def build_body_frame(
    parent: tk.Misc, vars_: BodyVars, cb: BodyCallbacks, *, profile_first: bool
) -> BodyWidgets:
    """Build the whole tab into ``parent``; return what the controller needs."""
    frame = tk.Frame(parent, bg=BG)
    tk.Label(frame, text="Body", font=(*_font(TITLE), "bold"), bg=BG, fg=FG).pack(
        pady=(MD, SM)
    )
    inner = tk.Frame(frame, bg=BG)
    inner.pack(fill="both", expand=True, padx=MD)
    if profile_first:
        _build_profile(inner, vars_, cb)
    _build_goal(inner, vars_, cb)
    columns = tk.Frame(inner, bg=BG)
    columns.pack(anchor="w", pady=(MD, 0))
    left = tk.Frame(columns, bg=BG)
    left.pack(side="left", anchor="n", padx=(0, MD))
    right = tk.Frame(columns, bg=BG)
    right.pack(side="left", anchor="n")
    canvas = _build_left(left, vars_, cb)
    _build_right(right, vars_, cb)
    if not profile_first:
        _build_profile(inner, vars_, cb)
    logs = vars_.logs
    pair = (logs.body_fat, logs.fat_day)
    _dated_row(inner, "Body fat %", pair, (cb.save_body_fat, cb.delete_body_fat))
    _block(inner, vars_.blocks["bodyfat"])
    return BodyWidgets(frame=frame, canvas=canvas)
