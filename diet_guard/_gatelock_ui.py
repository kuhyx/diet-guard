"""Widget construction for the diet_guard meal gate.

This module owns the *view* half of the gate: the palette, the data bundles
that hold the live string variables and the interactive widgets, and the pure
functions that lay the window out.  It deliberately knows nothing about slot
logic, nutrition maths, or logging -- the controller (:mod:`._gatelock`) keeps
all of that.  Splitting the construction out keeps each file focused and within
a readable size; the controller imports :func:`build_layout` and wires events
to the widgets it gets back.

The build functions take only public parameters (the root, the string-variable
bundle, and a small callbacks bundle) and return the populated widget bundle.
Event bindings that map to controller methods are left to the controller, so no
controller internals ever cross the module boundary.
"""

from __future__ import annotations

import tkinter as tk
from typing import TYPE_CHECKING

from gatelock import LockConfig

from diet_guard._gatelock_buttons import make_button
from diet_guard._gatelock_spacing import MD, SM, XS
from diet_guard._gatelock_typography import (
    BODY,
    CAPTION,
    DISPLAY,
    LABEL,
    SUBTITLE,
    TITLE,
)
from diet_guard._gatelock_ui_types import (
    GateCallbacks,
    GateEntryVars,
    GateVars,
    GateWidgets,
    _MacroEntries,
)

if TYPE_CHECKING:
    from collections.abc import Callable

# Palette: sourced from the shared gatelock LockConfig (unified-design-system)
# instead of locally-invented hex literals -- see DESIGN_AUDIT_TODO.md. BG/FG/
# ERR stay as re-exports since _gatelock_mealflow and _gatelock_calendar
# already import them by name; they now track LockConfig instead of a
# separate, driftable copy.
_COLORS = LockConfig()
BG = _COLORS.bg
FG = _COLORS.fg
ERR = _COLORS.danger
_ACCENT = _COLORS.accent
_FIELD_BG = _COLORS.field_bg
_MUTED = _COLORS.muted
_FONT = _COLORS.font_family
# Number of food-bank / staple / OFF suggestions shown in the picker list.
SUGGESTION_ROWS = 5
# Grams a label's macros are assumed to describe when the "per" field is blank.
DEFAULT_PER_GRAMS = 100.0
# Unit-selector choices for how a portion is measured.
UNIT_GRAMS = "grams"
UNIT_ITEMS = "items"
# Per-basis label prefixes for the two measuring modes.
BASIS_PREFIX_GRAMS = "Nutrition as on the label — per"
BASIS_PREFIX_ITEMS = "Nutrition per 1 item ≈"


__all__ = [
    "DEFAULT_PER_GRAMS",
    "UNIT_GRAMS",
    "GateCallbacks",
    "GateEntryVars",
    "GateVars",
    "GateWidgets",
    "_MacroEntries",
    "build_layout",
    "is_numeric_or_blank",
    "make_vars",
]


def make_vars(root: tk.Misc) -> GateVars:
    """Create the gate's string variables, all mastered to ``root``."""
    return GateVars(
        status=tk.StringVar(master=root, value=""),
        slot_header=tk.StringVar(master=root, value=""),
        preview=tk.StringVar(master=root, value=""),
        projection=tk.StringVar(master=root, value=""),
        cal_headline=tk.StringVar(master=root, value=""),
        dashboard=tk.StringVar(master=root, value=""),
        unit=tk.StringVar(master=root, value=UNIT_GRAMS),
        entries=GateEntryVars(
            amount=tk.StringVar(master=root, value=""),
            per=tk.StringVar(master=root, value=f"{DEFAULT_PER_GRAMS:g}"),
            kcal=tk.StringVar(master=root, value=""),
            protein=tk.StringVar(master=root, value=""),
            carbs=tk.StringVar(master=root, value=""),
            fat=tk.StringVar(master=root, value=""),
        ),
    )


def is_numeric_or_blank(proposed: str) -> bool:
    """Validate-on-key predicate: allow only a blank field or a number."""
    if proposed == "":
        return True
    try:
        float(proposed)
    except ValueError:
        return False
    return True


def _numeric_entry(
    root: tk.Misc, parent: tk.Frame, *, width: int, variable: tk.StringVar
) -> tk.Entry:
    """Return an entry that only accepts a number or a blank string."""
    vcmd = (root.register(is_numeric_or_blank), "%P")
    return tk.Entry(
        parent,
        textvariable=variable,
        font=(_FONT, BODY),
        width=width,
        bg=_FIELD_BG,
        fg=FG,
        insertbackground=FG,
        justify="center",
        validate="key",
        validatecommand=vcmd,
    )


def _macro_cell(
    root: tk.Misc, row: tk.Frame, label: str, variable: tk.StringVar
) -> tk.Entry:
    """Pack one small labelled numeric entry into the macro row."""
    cell = tk.Frame(row, bg=BG)
    cell.pack(side="left", padx=SM)
    tk.Label(cell, text=label, font=(_FONT, CAPTION), bg=BG, fg=FG).pack()
    entry = _numeric_entry(root, cell, width=7, variable=variable)
    entry.pack(ipady=XS)
    return entry


def _build_desc(parent: tk.Frame) -> tk.Text:
    """Build and return the multi-line "what did you eat?" description box.

    A multi-line ``Text`` (not an ``Entry``) so a long restaurant description
    wraps onto a second line and stays fully visible, instead of scrolling off
    the right edge where the end can no longer be read.
    """
    tk.Label(
        parent,
        text="What did you eat?",
        font=(_FONT, LABEL),
        bg=BG,
        fg=FG,
    ).pack()
    text = tk.Text(
        parent,
        font=(_FONT, BODY),
        width=64,
        height=2,
        wrap="word",
        bg=_FIELD_BG,
        fg=FG,
        insertbackground=FG,
        highlightthickness=1,
        highlightbackground=_MUTED,
    )
    text.pack(pady=(XS, SM))
    return text


def _build_suggestion_box(parent: tk.Frame) -> tk.Listbox:
    """Build the food-bank / staple / OFF picker list and return it."""
    box = tk.Listbox(
        parent,
        font=(_FONT, BODY),
        width=52,
        height=SUGGESTION_ROWS,
        bg=_FIELD_BG,
        fg=FG,
        selectbackground=_ACCENT,
        selectforeground=_COLORS.on_fill,
        activestyle="none",
        highlightthickness=0,
    )
    box.pack(pady=(0, SM))
    return box


def _build_amount_row(
    root: tk.Misc,
    parent: tk.Frame,
    vars_: GateVars,
    on_unit_change: Callable[[str], None],
) -> tk.Entry:
    """Build the "how much did you eat?" amount + unit row; return the entry."""
    tk.Label(
        parent,
        text="How much did you eat?",
        font=(_FONT, LABEL),
        bg=BG,
        fg=FG,
    ).pack()
    row = tk.Frame(parent, bg=BG)
    row.pack(pady=(XS, SM))
    amount_entry = _numeric_entry(root, row, width=10, variable=vars_.entries.amount)
    amount_entry.pack(side="left", ipady=XS)
    unit_menu = tk.OptionMenu(
        row,
        vars_.unit,
        UNIT_GRAMS,
        UNIT_ITEMS,
        command=on_unit_change,
    )
    unit_menu.configure(
        font=(_FONT, LABEL),
        bg=_FIELD_BG,
        fg=FG,
        activebackground=_ACCENT,
        highlightthickness=0,
    )
    unit_menu.pack(side="left", padx=(SM, 0))
    return amount_entry


def _build_macro_section(
    root: tk.Misc,
    parent: tk.Frame,
    vars_: GateVars,
) -> tuple[tk.Label, tk.Entry, _MacroEntries]:
    """Build the per-basis field and macro row.

    Returns the basis-prefix label, the "per" entry, and the four macro entries,
    for the caller to store in the widget bundle.
    """
    basis = tk.Frame(parent, bg=BG)
    basis.pack()
    basis_prefix = tk.Label(
        basis,
        text=BASIS_PREFIX_GRAMS,
        font=(_FONT, LABEL),
        bg=BG,
        fg=FG,
    )
    basis_prefix.pack(side="left")
    per_entry = _numeric_entry(root, basis, width=5, variable=vars_.entries.per)
    per_entry.pack(side="left", padx=XS, ipady=XS)
    tk.Label(
        basis,
        text="g  (leave calories blank to look it up):",
        font=(_FONT, LABEL),
        bg=BG,
        fg=FG,
    ).pack(side="left")

    row = tk.Frame(parent, bg=BG)
    row.pack(pady=(XS, SM))
    macros = _MacroEntries(
        kcal=_macro_cell(root, row, "kcal", vars_.entries.kcal),
        protein=_macro_cell(root, row, "P", vars_.entries.protein),
        carbs=_macro_cell(root, row, "C", vars_.entries.carbs),
        fat=_macro_cell(root, row, "F", vars_.entries.fat),
    )
    return basis_prefix, per_entry, macros


def _build_dashboard(parent: tk.Frame, vars_: GateVars) -> None:
    """Build the running "how am I doing today" panel.

    The calorie line is large and prominent (the number the user steers by); the
    meal list and macros sit beneath it in a smaller monospace block.
    """
    tk.Label(
        parent,
        textvariable=vars_.cal_headline,
        font=(_FONT, TITLE, "bold"),
        bg=BG,
        fg=_ACCENT,
    ).pack(pady=(MD, 0))
    tk.Label(
        parent,
        textvariable=vars_.dashboard,
        font=("Courier", CAPTION),
        bg=BG,
        fg=_MUTED,
        justify="left",
        anchor="w",
        wraplength=900,
    ).pack(pady=(XS, 0))


def build_layout(
    root: tk.Misc,
    vars_: GateVars,
    callbacks: GateCallbacks,
    *,
    demo_mode: bool,
) -> GateWidgets:
    """Lay out the whole gate UI and return the widgets the controller drives.

    The controller calls this once (after configuring the window) and is then
    responsible for binding per-keystroke events to the returned widgets.
    """
    frame = tk.Frame(root, bg=BG)
    frame.place(relx=0.5, rely=0.5, anchor="center")

    tk.Label(
        frame,
        text="🍽  Diet Gate",
        font=(_FONT, DISPLAY, "bold"),
        bg=BG,
        fg=_ACCENT,
    ).pack(pady=(0, XS))
    tk.Label(
        frame,
        textvariable=vars_.slot_header,
        font=(_FONT, SUBTITLE, "bold"),
        bg=BG,
        fg=FG,
        wraplength=900,
        justify="center",
    ).pack(pady=(0, MD))

    desc_text = _build_desc(frame)
    suggestion_box = _build_suggestion_box(frame)
    amount_entry = _build_amount_row(
        root,
        frame,
        vars_,
        callbacks.on_unit_change,
    )
    basis_prefix, per_entry, macros = _build_macro_section(root, frame, vars_)

    tk.Label(
        frame,
        textvariable=vars_.projection,
        font=(_FONT, LABEL, "bold"),
        bg=BG,
        fg=FG,
        wraplength=900,
        justify="center",
    ).pack(pady=(XS, XS))
    tk.Label(
        frame,
        textvariable=vars_.preview,
        font=(_FONT, BODY, "bold"),
        bg=BG,
        fg=_ACCENT,
        wraplength=900,
        justify="center",
    ).pack(pady=(XS, SM))

    make_button(
        frame,
        text="Log & Continue",
        variant="primary",
        command=callbacks.on_submit,
    ).pack(pady=(XS, SM))

    # Manual pull for a meal already logged on another device (the phone) but
    # not yet propagated to this machine -- saves re-typing it to unlock.
    make_button(
        frame,
        text="⟳ Fetch from sync",
        variant="secondary",
        command=callbacks.on_fetch_sync,
        bold=False,
    ).pack(pady=(0, SM))

    status_label = tk.Label(
        frame,
        textvariable=vars_.status,
        font=(_FONT, LABEL),
        bg=BG,
        fg=FG,
        wraplength=900,
        justify="center",
    )
    status_label.pack()

    _build_dashboard(frame, vars_)

    if demo_mode:
        make_button(
            root,
            text="✕ Close Demo",
            variant="danger",
            command=callbacks.on_close,
            bold=False,
        ).place(x=10, y=10)

    return GateWidgets(
        frame=frame,
        desc_text=desc_text,
        amount_entry=amount_entry,
        per_entry=per_entry,
        basis_prefix=basis_prefix,
        macros=macros,
        suggestion_box=suggestion_box,
        status_label=status_label,
    )
