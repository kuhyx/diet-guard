"""Assembly of the gate's "Log Meal" tab.

Split out of :mod:`._gatelock_ui` to keep every gate module under the repo's
250-line limit.  :mod:`._gatelock_fields` builds the individual input widgets;
this half packs them, the dashboard, and the buttons into one scrollable
surface and returns the bundle the controller drives.

.. note::
   This module imports ``tkinter`` and builds widgets, so it **must** appear in
   ``diet_guard.tests._gate_fixtures._GATE_TK_MODULES``.  A module left out of
   that set builds real Tk widgets under pytest against fake parents.
   ``test_gate_tk_modules_complete`` enforces this.
"""

from __future__ import annotations

import tkinter as tk

from gatelock import ButtonStyle, ScrollableSurface, make_button

from diet_guard._gatelock_fields import (
    build_amount_row,
    build_desc,
    build_macro_section,
    build_suggestion_box,
)
from diet_guard._gatelock_spacing import SM, XS
from diet_guard._gatelock_typography import BODY, CAPTION, LABEL, SUBTITLE, TITLE
from diet_guard._gatelock_ui import (
    _ACCENT,
    _COLORS,
    _FONT,
    _MUTED,
    _WRAP_PX,
    BG,
    FG,
)
from diet_guard._gatelock_ui_types import GateCallbacks, GateVars, GateWidgets

__all__ = ["build_layout"]


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


def _build_header(body: tk.Frame, vars_: GateVars) -> None:
    """Pack the title and the current-slot header."""
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


def _build_readouts(body: tk.Frame, vars_: GateVars) -> None:
    """Pack the projection and preview lines beneath the input fields."""
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


def _build_actions(body: tk.Frame, callbacks: GateCallbacks) -> None:
    """Pack the submit button and the manual sync-fetch button."""
    make_button(
        body,
        _COLORS,
        "Log & Continue",
        callbacks.on_submit,
    ).pack(pady=(XS, XS))

    # Both "pull it in from elsewhere" actions share one row: stacking them
    # cost 42px, which pushed the tab past the viewport on a 1366x768 screen
    # (test_gate_fits_the_primary_screen). Side by side they fit.
    pulls = tk.Frame(body, bg=BG)
    pulls.pack(pady=(0, XS))

    # A meal already logged on another device (the phone) but not yet
    # propagated here -- saves re-typing it to unlock.
    make_button(
        pulls,
        _COLORS,
        "⟳ Fetch from sync",
        callbacks.on_fetch_sync,
        ButtonStyle(variant="secondary", bold=False),
    ).pack(side="left", padx=(0, XS))

    # Today's catering delivery, with its real macros. Loading only *offers*
    # the dishes -- each still has to be checked and submitted, because a
    # delivered meal is not an eaten meal.
    make_button(
        pulls,
        _COLORS,
        "🍱 Today's delivery",
        callbacks.on_load_delivery,
        ButtonStyle(variant="secondary", bold=False),
    ).pack(side="left")


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

    _build_header(body, vars_)

    desc_text = build_desc(body)
    suggestion_box = build_suggestion_box(body)
    amount_entry = build_amount_row(
        root,
        body,
        vars_,
        callbacks.on_unit_change,
    )
    basis_prefix, per_entry, macros = build_macro_section(root, body, vars_)

    _build_readouts(body, vars_)
    _build_actions(body, callbacks)

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
            _COLORS,
            "✕ Close Demo",
            callbacks.on_close,
            ButtonStyle(variant="danger", bold=False),
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
