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

from dataclasses import dataclass
import tkinter as tk
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable

# Palette (mirrors the screen locker's dark, high-contrast lock aesthetic).
BG = "#1a1a1a"
FG = "#e0e0e0"
_ACCENT = "#00ff88"
ERR = "#ff6666"
_FIELD_BG = "#2a2a2a"
_MUTED = "#9a9a9a"
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


@dataclass
class _MacroEntries:
    """The four macro entry widgets, in (kcal, protein, carbs, fat) order."""

    kcal: tk.Entry
    protein: tk.Entry
    carbs: tk.Entry
    fat: tk.Entry


@dataclass
class GateVars:
    """Tk string variables bound to the gate's live, auto-updating fields."""

    status: tk.StringVar
    slot_header: tk.StringVar
    preview: tk.StringVar
    projection: tk.StringVar
    cal_headline: tk.StringVar
    dashboard: tk.StringVar
    meal_summary: tk.StringVar
    unit: tk.StringVar


@dataclass
class GateWidgets:
    """Interactive widgets the controller reads back after the UI is built."""

    desc_text: tk.Text
    amount_entry: tk.Entry
    per_entry: tk.Entry
    basis_prefix: tk.Label
    macros: _MacroEntries
    suggestion_box: tk.Listbox
    meal_name_entry: tk.Entry
    status_label: tk.Label


@dataclass
class GateCallbacks:
    """Construction-time commands the widgets fire (not key/event bindings).

    These are the callbacks that must be supplied when a widget is created --
    option-menu and button commands.  Per-keystroke event bindings are wired by
    the controller after the layout is built, so they are not carried here.
    """

    on_unit_change: Callable[[str], None]
    on_submit: Callable[[], None]
    on_close: Callable[[], None]
    on_add_item: Callable[[], None]


def make_vars(root: tk.Misc) -> GateVars:
    """Create the gate's string variables, all mastered to ``root``."""
    return GateVars(
        status=tk.StringVar(master=root, value=""),
        slot_header=tk.StringVar(master=root, value=""),
        preview=tk.StringVar(master=root, value=""),
        projection=tk.StringVar(master=root, value=""),
        cal_headline=tk.StringVar(master=root, value=""),
        dashboard=tk.StringVar(master=root, value=""),
        meal_summary=tk.StringVar(master=root, value=""),
        unit=tk.StringVar(master=root, value=UNIT_GRAMS),
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


def _numeric_entry(root: tk.Misc, parent: tk.Frame, *, width: int) -> tk.Entry:
    """Return an entry that only accepts a number or a blank string."""
    vcmd = (root.register(is_numeric_or_blank), "%P")
    return tk.Entry(
        parent,
        font=("Arial", 15),
        width=width,
        bg=_FIELD_BG,
        fg=FG,
        insertbackground=FG,
        justify="center",
        validate="key",
        validatecommand=vcmd,
    )


def _macro_cell(root: tk.Misc, row: tk.Frame, label: str) -> tk.Entry:
    """Pack one small labelled numeric entry into the macro row."""
    cell = tk.Frame(row, bg=BG)
    cell.pack(side="left", padx=6)
    tk.Label(cell, text=label, font=("Arial", 11), bg=BG, fg=FG).pack()
    entry = _numeric_entry(root, cell, width=7)
    entry.pack(ipady=3)
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
        font=("Arial", 12),
        bg=BG,
        fg=FG,
    ).pack()
    text = tk.Text(
        parent,
        font=("Arial", 15),
        width=64,
        height=2,
        wrap="word",
        bg=_FIELD_BG,
        fg=FG,
        insertbackground=FG,
        highlightthickness=1,
        highlightbackground=_MUTED,
    )
    text.pack(pady=(2, 6))
    return text


def _build_suggestion_box(parent: tk.Frame) -> tk.Listbox:
    """Build the food-bank / staple / OFF picker list and return it."""
    box = tk.Listbox(
        parent,
        font=("Arial", 12),
        width=52,
        height=SUGGESTION_ROWS,
        bg=_FIELD_BG,
        fg=FG,
        selectbackground=_ACCENT,
        selectforeground="#003322",
        activestyle="none",
        highlightthickness=0,
    )
    box.pack(pady=(0, 8))
    return box


def _build_amount_row(
    root: tk.Misc,
    parent: tk.Frame,
    unit_var: tk.StringVar,
    on_unit_change: Callable[[str], None],
) -> tk.Entry:
    """Build the "how much did you eat?" amount + unit row; return the entry."""
    tk.Label(
        parent,
        text="How much did you eat?",
        font=("Arial", 12),
        bg=BG,
        fg=FG,
    ).pack()
    row = tk.Frame(parent, bg=BG)
    row.pack(pady=(2, 6))
    amount_entry = _numeric_entry(root, row, width=10)
    amount_entry.pack(side="left", ipady=3)
    unit_menu = tk.OptionMenu(
        row,
        unit_var,
        UNIT_GRAMS,
        UNIT_ITEMS,
        command=on_unit_change,
    )
    unit_menu.configure(
        font=("Arial", 12),
        bg=_FIELD_BG,
        fg=FG,
        activebackground=_ACCENT,
        highlightthickness=0,
    )
    unit_menu.pack(side="left", padx=(8, 0))
    return amount_entry


def _build_macro_section(
    root: tk.Misc,
    parent: tk.Frame,
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
        font=("Arial", 12),
        bg=BG,
        fg=FG,
    )
    basis_prefix.pack(side="left")
    per_entry = _numeric_entry(root, basis, width=5)
    per_entry.insert(0, f"{DEFAULT_PER_GRAMS:g}")
    per_entry.pack(side="left", padx=4, ipady=2)
    tk.Label(
        basis,
        text="g  (leave calories blank to look it up):",
        font=("Arial", 12),
        bg=BG,
        fg=FG,
    ).pack(side="left")

    row = tk.Frame(parent, bg=BG)
    row.pack(pady=(2, 6))
    macros = _MacroEntries(
        kcal=_macro_cell(root, row, "kcal"),
        protein=_macro_cell(root, row, "P"),
        carbs=_macro_cell(root, row, "C"),
        fat=_macro_cell(root, row, "F"),
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
        font=("Arial", 22, "bold"),
        bg=BG,
        fg=_ACCENT,
    ).pack(pady=(12, 0))
    tk.Label(
        parent,
        textvariable=vars_.dashboard,
        font=("Courier", 11),
        bg=BG,
        fg=_MUTED,
        justify="left",
        anchor="w",
        wraplength=900,
    ).pack(pady=(2, 0))


def _build_meal_controls(
    parent: tk.Frame,
    vars_: GateVars,
    on_add_item: Callable[[], None],
) -> tk.Entry:
    """Build the optional multi-item meal row; return the meal-name entry.

    Logging stays one-tap for a single food; these controls only matter when a
    meal has several separately-macroed parts (a dinner of salad + chicken +
    rice).  "Add item" banks the part onto the meal-in-progress and clears the
    form for the next one; "Log & Continue" then logs the summed meal.
    """
    row = tk.Frame(parent, bg=BG)
    row.pack(pady=(2, 2))
    tk.Label(
        row,
        text="Meal name (optional):",
        font=("Arial", 11),
        bg=BG,
        fg=FG,
    ).pack(side="left")
    meal_name_entry = tk.Entry(
        row,
        font=("Arial", 13),
        width=18,
        bg=_FIELD_BG,
        fg=FG,
        insertbackground=FG,
    )
    meal_name_entry.pack(side="left", padx=(6, 8), ipady=2)
    tk.Button(
        row,
        text="+ Add item",
        font=("Arial", 12, "bold"),
        bg=_FIELD_BG,
        fg=_ACCENT,
        activebackground="#333333",
        cursor="hand2",
        command=on_add_item,
    ).pack(side="left")
    tk.Label(
        parent,
        textvariable=vars_.meal_summary,
        font=("Arial", 11),
        bg=BG,
        fg=_MUTED,
        wraplength=900,
        justify="center",
    ).pack(pady=(0, 2))
    return meal_name_entry


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
        font=("Arial", 30, "bold"),
        bg=BG,
        fg=_ACCENT,
    ).pack(pady=(0, 4))
    tk.Label(
        frame,
        textvariable=vars_.slot_header,
        font=("Arial", 16, "bold"),
        bg=BG,
        fg=FG,
        wraplength=900,
        justify="center",
    ).pack(pady=(0, 10))

    desc_text = _build_desc(frame)
    suggestion_box = _build_suggestion_box(frame)
    amount_entry = _build_amount_row(
        root,
        frame,
        vars_.unit,
        callbacks.on_unit_change,
    )
    basis_prefix, per_entry, macros = _build_macro_section(root, frame)

    tk.Label(
        frame,
        textvariable=vars_.projection,
        font=("Arial", 13, "bold"),
        bg=BG,
        fg=FG,
        wraplength=900,
        justify="center",
    ).pack(pady=(2, 2))
    tk.Label(
        frame,
        textvariable=vars_.preview,
        font=("Arial", 14, "bold"),
        bg=BG,
        fg=_ACCENT,
        wraplength=900,
        justify="center",
    ).pack(pady=(2, 6))

    meal_name_entry = _build_meal_controls(frame, vars_, callbacks.on_add_item)

    tk.Button(
        frame,
        text="Log & Continue",
        font=("Arial", 15, "bold"),
        bg=_ACCENT,
        fg="#003322",
        activebackground="#00cc66",
        cursor="hand2",
        command=callbacks.on_submit,
    ).pack(pady=(4, 6))

    status_label = tk.Label(
        frame,
        textvariable=vars_.status,
        font=("Arial", 12),
        bg=BG,
        fg=FG,
        wraplength=900,
        justify="center",
    )
    status_label.pack()

    _build_dashboard(frame, vars_)

    if demo_mode:
        tk.Button(
            root,
            text="✕ Close Demo",
            font=("Arial", 12),
            bg="#ff4444",
            fg="white",
            command=callbacks.on_close,
            cursor="hand2",
        ).place(x=10, y=10)

    return GateWidgets(
        desc_text=desc_text,
        amount_entry=amount_entry,
        per_entry=per_entry,
        basis_prefix=basis_prefix,
        macros=macros,
        suggestion_box=suggestion_box,
        meal_name_entry=meal_name_entry,
        status_label=status_label,
    )
