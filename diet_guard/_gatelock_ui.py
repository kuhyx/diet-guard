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

from gatelock import LockConfig, ScrollableSurface, escape_text_tab_trap

from diet_guard._gatelock_buttons import make_button
from diet_guard._gatelock_spacing import SM, XS
from diet_guard._gatelock_typography import (
    BODY,
    CAPTION,
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
        # focus_kwargs() sets highlightcolor (the *focused* ring). This
        # previously set only highlightbackground, which is the UNFOCUSED ring
        # -- so the box outlined while unfocused and went black (invisible on
        # bg) the moment it took focus, exactly inverting the affordance.
        **_COLORS.focus_kwargs(),
    )
    text.pack(pady=(XS, XS))
    _escape_text_tab_trap(text)
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
        # Was highlightthickness=0, which removed the focus ring entirely. The
        # list *is* arrow-key navigable, so it was keyboard-usable with no
        # visual indication of where focus was.
        **_COLORS.focus_kwargs(),
    )
    box.pack(pady=(0, XS))
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
    row.pack(pady=(XS, XS))
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
    ).pack(pady=(SM, 0))
    tk.Label(
        parent,
        textvariable=vars_.dashboard,
        font=("Courier", CAPTION),
        bg=BG,
        fg=_MUTED,
        justify="left",
        anchor="w",
        wraplength=_WRAP_PX,
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

    The content lives inside a :class:`~gatelock.ScrollableSurface` rather than
    a ``place``-centered frame. It has to: this tab requires ~700px even when
    empty and grows a line per logged meal, so on a 1366x768 screen it exceeded
    the notebook's content pane and a centered frame clipped it *symmetrically*
    -- losing the "Diet Gate" title and the slot header off the top while the
    calorie headline and dashboard went off the bottom, with no scrollbar to
    recover either. The viewport also makes the overflow keyboard-reachable,
    which matters because this is a hard lock the user cannot leave without
    logging a meal. See ``tests/measure_gate_layout.py``.
    """
    surface = ScrollableSurface(root, _COLORS)
    frame = surface.container
    body = surface.content

    tk.Label(
        body,
        text="🍽  Diet Gate",
        font=(_FONT, TITLE, "bold"),
        bg=BG,
        fg=_ACCENT,
    ).pack(pady=(0, XS))
    tk.Label(
        body,
        textvariable=vars_.slot_header,
        font=(_FONT, SUBTITLE, "bold"),
        bg=BG,
        fg=FG,
        wraplength=_WRAP_PX,
        justify="center",
    ).pack(pady=(0, SM))

    desc_text = _build_desc(body)
    suggestion_box = _build_suggestion_box(body)
    amount_entry = _build_amount_row(
        root,
        body,
        vars_,
        callbacks.on_unit_change,
    )
    basis_prefix, per_entry, macros = _build_macro_section(root, body, vars_)

    tk.Label(
        body,
        textvariable=vars_.projection,
        font=(_FONT, LABEL, "bold"),
        bg=BG,
        fg=FG,
        wraplength=_WRAP_PX,
        justify="center",
    ).pack(pady=(XS, XS))
    tk.Label(
        body,
        textvariable=vars_.preview,
        font=(_FONT, BODY, "bold"),
        bg=BG,
        fg=_ACCENT,
        wraplength=_WRAP_PX,
        justify="center",
    ).pack(pady=(XS, XS))

    make_button(
        body,
        text="Log & Continue",
        variant="primary",
        command=callbacks.on_submit,
    ).pack(pady=(XS, XS))

    # Manual pull for a meal already logged on another device (the phone) but
    # not yet propagated to this machine -- saves re-typing it to unlock.
    make_button(
        body,
        text="⟳ Fetch from sync",
        variant="secondary",
        command=callbacks.on_fetch_sync,
        bold=False,
    ).pack(pady=(0, XS))

    status_label = tk.Label(
        body,
        textvariable=vars_.status,
        font=(_FONT, LABEL),
        bg=BG,
        fg=FG,
        wraplength=_WRAP_PX,
        justify="center",
    )
    status_label.pack()

    _build_dashboard(body, vars_)

    # Wire focus-following and reset the view now that the content exists.
    # Without this, Tab walks onto fields scrolled out of sight -- clipping does
    # not remove a widget from the tab chain.
    surface.finalize()

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
