"""Palette and shared leaf widgets for the diet_guard meal gate.

This module owns the *view* half's shared foundation: the palette every gate
module reads, the layout constants, and the small leaf-widget helpers.  It
deliberately knows nothing about slot logic, nutrition maths, or logging --
the controller (:mod:`._gatelock`) keeps all of that.

Building the tab itself spans two siblings, so each file stays under the repo's
250-line limit: :mod:`._gatelock_fields` builds the individual input widgets,
and :mod:`._gatelock_layout` packs them into the surface, exporting
:func:`build_layout`.

The build functions take only public parameters (the root, the string-variable
bundle, and a small callbacks bundle) and return the populated widget bundle.
Event bindings that map to controller methods are left to the controller, so no
controller internals ever cross the module boundary.
"""

from __future__ import annotations

import tkinter as tk

from gatelock import (
    LockConfig,
    escape_text_tab_trap,
)

from diet_guard._gatelock_spacing import SM, XS
from diet_guard._gatelock_typography import (
    BODY,
    CAPTION,
)
from diet_guard._gatelock_ui_types import (
    GateCallbacks,
    GateEntryVars,
    GateVars,
    GateWidgets,
    _MacroEntries,
)

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
# Wrap width for the gate's prose labels, in px. 640 is tokens.md's line-length
# cap (rule 21, 40rem / ~65-70 characters). This was 900 at five call sites,
# which both exceeded the cap and -- more practically -- forced a 900px-wide
# layout on a 1024px screen, since a label's wrap width feeds its requested
# width and therefore the whole centered column's.
_WRAP_PX = 640


__all__ = [
    "DEFAULT_PER_GRAMS",
    "UNIT_GRAMS",
    "GateCallbacks",
    "GateEntryVars",
    "GateVars",
    "GateWidgets",
    "_MacroEntries",
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
        **_COLORS.focus_kwargs(),
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


# Re-exported from gatelock so the four lockers share one implementation of
# this Tk-default workaround rather than each carrying a copy. Kept as a
# module-level name because the gate's own tests bind to it here.
_escape_text_tab_trap = escape_text_tab_trap


def escape_tab_trap(text: tk.Text) -> None:
    """Let Tab leave ``text`` instead of inserting a tab character.

    A thin public indirection over :data:`_escape_text_tab_trap`, resolved at
    **call** time.  :mod:`._gatelock_fields`, which owns the only call site,
    goes through this rather than importing the private name by value: the
    keyboard test patches ``_gatelock_ui._escape_text_tab_trap``, and a
    by-value import elsewhere would bind a copy the patch can never reach --
    silently disabling the Tab-trap escape while the suite stays green.
    """
    _escape_text_tab_trap(text)
