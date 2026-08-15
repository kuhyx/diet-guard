"""Field widgets of the gate's "Log Meal" tab.

Split out of :mod:`._gatelock_ui` to keep every gate module under the repo's
250-line limit.  This half builds the *input* widgets -- the description box,
the suggestion picker, the amount/unit row, and the macro section --
:mod:`._gatelock_layout` assembles them into the tab.

The palette and the leaf helpers stay in :mod:`._gatelock_ui`, which is the
single ``LockConfig()`` all gate modules read; deliberately not re-derived
here, since a separate copy is exactly what drifted before (see
``DESIGN_AUDIT_TODO.md``).

.. note::
   This module imports ``tkinter`` and builds widgets, so it **must** appear in
   ``diet_guard.tests._gate_fixtures._GATE_TK_MODULES``.  A module left out of
   that set builds real Tk widgets under pytest against fake parents.
   ``test_gate_tk_modules_complete`` enforces this.
"""

from __future__ import annotations

import tkinter as tk
from typing import TYPE_CHECKING

from diet_guard import _gatelock_ui
from diet_guard._gatelock_spacing import SM, XS
from diet_guard._gatelock_typography import BODY, LABEL
from diet_guard._gatelock_ui import (
    _ACCENT,
    _COLORS,
    _FIELD_BG,
    _FONT,
    BASIS_PREFIX_GRAMS,
    BG,
    FG,
    SUGGESTION_ROWS,
    UNIT_GRAMS,
    UNIT_ITEMS,
    _macro_cell,
    _numeric_entry,
)
from diet_guard._gatelock_ui_types import _MacroEntries

if TYPE_CHECKING:
    from collections.abc import Callable

    from diet_guard._gatelock_ui_types import GateVars

__all__ = [
    "build_amount_row",
    "build_desc",
    "build_macro_section",
    "build_suggestion_box",
]


def build_desc(parent: tk.Frame) -> tk.Text:
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
        # focus_kwargs() sets highlightcolor (the *focused* ring). This
        # previously set only highlightbackground, which is the UNFOCUSED ring
        # -- so the box outlined while unfocused and went black (invisible on
        # bg) the moment it took focus, exactly inverting the affordance.
        **_COLORS.focus_kwargs(),
    )
    text.pack(pady=(XS, XS))
    # Through the module, not a by-value import: the keyboard test patches
    # ``_gatelock_ui._escape_text_tab_trap``, and ``escape_tab_trap`` resolves
    # it at call time so the patch still bites. Importing the name directly
    # would bind a copy the patch can never reach -- a fail-open that disables
    # the Tab-trap escape with a green suite.
    _gatelock_ui.escape_tab_trap(text)
    return text


def build_suggestion_box(parent: tk.Frame) -> tk.Listbox:
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
        # Was highlightthickness=0, which removed the focus ring entirely. The
        # list *is* arrow-key navigable, so it was keyboard-usable with no
        # visual indication of where focus was.
        **_COLORS.focus_kwargs(),
    )
    box.pack(pady=(0, XS))
    return box


def build_amount_row(
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
    row.pack(pady=(XS, XS))
    amount_entry = _numeric_entry(root, row, width=10, variable=vars_.entries.amount)
    amount_entry.pack(side="left", ipady=XS)
    _build_unit_selector(row, vars_, on_unit_change)
    return amount_entry


def _build_unit_selector(
    row: tk.Frame,
    vars_: GateVars,
    on_unit_change: Callable[[str], None],
) -> None:
    """Build the grams/items selector as focusable radio buttons.

    Deliberately **not** a ``tk.OptionMenu``, which this used to be, for two
    independent reasons:

    1. **It was unreachable by keyboard.** ``OptionMenu``'s underlying
       ``Menubutton`` defaults to ``takefocus=0``, so ``::tk::FocusOK`` rejects
       it and it never appears in the tab ring (verified: the ring ran
       Entry -> Text -> Listbox -> Button -> TNotebook and skipped it). Since
       the unit rescales the entire entry, a pointerless user could not switch
       between "250 grams" and "3 items" inside a lock they cannot leave
       without logging a meal.
    2. **A posted menu is unsafe on a lock surface.** A dropped-down Tk menu is
       a separate override-redirect toplevel that steals the Tk grab, which
       gatelock's recovery tick then kills within a second. That is the
       documented 2026-07-26 failure where a frozen sport selector logged a walk
       as table tennis, and it is why screen-locker statically bans
       ``OptionMenu`` on lock surfaces.

    ``tk.Radiobutton`` avoids both: it is in the tab ring by default and accepts
    **both** ``Space`` and ``Return`` (unlike ``tk.Button``, which on X11 binds
    only ``Space``), and it posts nothing.
    """
    for unit in (UNIT_GRAMS, UNIT_ITEMS):
        tk.Radiobutton(
            row,
            text=unit,
            value=unit,
            variable=vars_.unit,
            command=lambda u=unit: on_unit_change(u),
            font=(_FONT, LABEL),
            bg=BG,
            fg=FG,
            selectcolor=_FIELD_BG,
            activebackground=BG,
            activeforeground=_ACCENT,
            **_COLORS.focus_kwargs(),
        ).pack(side="left", padx=(SM, 0))


def build_macro_section(
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
    row.pack(pady=(XS, XS))
    macros = _MacroEntries(
        kcal=_macro_cell(root, row, "kcal", vars_.entries.kcal),
        protein=_macro_cell(root, row, "P", vars_.entries.protein),
        carbs=_macro_cell(root, row, "C", vars_.entries.carbs),
        fat=_macro_cell(root, row, "F", vars_.entries.fat),
    )
    return basis_prefix, per_entry, macros
