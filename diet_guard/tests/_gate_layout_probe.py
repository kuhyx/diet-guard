r"""Measure the gate layout against a target screen and prove it is reachable.

Import :func:`measure` from a test to assert the invariant. There is
deliberately no ``print``-based CLI here: ruff runs with ``--unsafe-fixes``,
whose ``T201`` fix *deletes* print statements, which silently turns a
diagnostic script into a no-op. The gate is ``test_gate_layout_fits.py``,
which fails rather than reports.

Test support, not a test: it lives under ``tests/`` (excluded from the
``test_*.py`` naming hook) rather than in the package, so its diagnostic-only
branches -- the no-viewport degradation path in particular -- are not held to
the package's 100%-coverage bar for code that only runs against a layout that
has not been fixed yet.

**What the invariant actually is.** It is not "the content fits" -- the Log Meal
tab legitimately grows a line per logged meal, so on a short screen it will
eventually exceed the pane. It is "nothing is unreachable": the content lives in
a scroll viewport, that viewport scrolls by keyboard, and focus moves the view to
follow. Before the viewport existed the content was ``place``-centered, so
overflow sheared the title off the top and the submit button off the bottom
simultaneously, with no scrollbar and no way back -- inside a hard lock the user
cannot leave without logging a meal.

``content_span`` is still reported because a layout that needs scrolling on a
*fresh boot* is worth knowing about even when it is technically reachable.

Run the gate with:
    xvfb-run -a -s "-screen 0 1366x768x24" \\
        python3 -m pytest diet_guard/tests/test_gate_layout_fits.py
"""

from __future__ import annotations

import tkinter as tk
from tkinter import ttk

from diet_guard._gatelock_layout import build_layout
from diet_guard._gatelock_ui import GateCallbacks, GateVars
from diet_guard._gatelock_ui_types import GateEntryVars
from diet_guard.tests._gate_focus_probe import _probe_viewport
from diet_guard.tests._gate_measurement import Measurement

# ttk.Notebook's tab strip is chrome the content pane never gets to use.
# Measured rather than assumed; see _notebook_overhead().
_FALLBACK_TAB_STRIP_PX = 44
# A realistic full day, as the dashboard renders it. Module-level so ruff's
# FLY002 (static-join-to-f-string) does not rewrite an inline join into one
# over-long line, which then trips E501.
_SAMPLE_DASHBOARD = (
    "08:00  oatmeal with milk and raisins -- 430 kcal",
    "12:00  chicken thigh, rice, cucumber -- 780 kcal",
    "16:00  greek yoghurt and a banana -- 260 kcal",
    "protein 118 / 140 g   carbs 210 g   fat 61 g",
    "protein target: 22 g remaining",
)


def _make_vars(*, populated: bool) -> GateVars:
    """Build the gate's Tk variables, optionally with realistic content.

    The empty case is *not* the worst case: the dashboard grows one line per
    logged meal, so a layout that fits on a fresh boot can still overflow by
    dinnertime. ``populated`` models a full day.
    """
    entries = GateEntryVars(
        amount=tk.StringVar(value="250" if populated else ""),
        per=tk.StringVar(value="100" if populated else ""),
        kcal=tk.StringVar(value="520" if populated else ""),
        protein=tk.StringVar(value="31" if populated else ""),
        carbs=tk.StringVar(value="44" if populated else ""),
        fat=tk.StringVar(value="18" if populated else ""),
    )
    dashboard = ""
    if populated:
        dashboard = "\n".join(_SAMPLE_DASHBOARD)
    return GateVars(
        status=tk.StringVar(value="Enter what you ate." if populated else ""),
        slot_header=tk.StringVar(
            value="20:00 meal not logged yet -- what did you eat?"
            if populated
            else "Log your meal"
        ),
        preview=tk.StringVar(value="520 kcal for 250 g" if populated else ""),
        projection=tk.StringVar(
            value="projected 1990 / 2100 kcal today" if populated else ""
        ),
        cal_headline=tk.StringVar(
            value="1470 kcal so far -- 630 left" if populated else ""
        ),
        dashboard=tk.StringVar(value=dashboard),
        unit=tk.StringVar(value="grams"),
        entries=entries,
    )


def _noop(*_args: object) -> None:
    """Swallow a widget callback; measurement never activates anything."""


def _notebook_overhead(root: tk.Misc) -> int:
    """Return the vertical px a ``ttk.Notebook`` tab strip costs.

    Measured from a throwaway notebook rather than hardcoded, so a theme or
    font change cannot silently invalidate the budget.
    """
    probe = ttk.Notebook(root)
    filler = tk.Frame(probe, width=200, height=100)
    probe.add(filler, text="Log Meal")
    probe.update_idletasks()
    overhead = probe.winfo_reqheight() - filler.winfo_reqheight()
    probe.destroy()
    return overhead if overhead > 0 else _FALLBACK_TAB_STRIP_PX


def measure(
    screen_w: int = 1366,
    screen_h: int = 768,
    *,
    populated: bool = True,
) -> Measurement:
    """Build the real gate layout inside a notebook and probe reachability.

    Args:
        screen_w: Target screen width in px.
        screen_h: Target screen height in px.
        populated: Fill the variables with a realistic full day of data.

    Returns:
        The measurement, including whether all content is keyboard-reachable.
    """
    root = tk.Tk()
    try:
        # Bypass the window manager. This measures whether the layout fits a
        # given panel, so the window must actually BE that size -- but a
        # tiling WM (i3 on the dev machine) retiles a managed toplevel to the
        # workspace instead, and `winfo_height()` then reports 0/1px. Every
        # measurement taken from that is noise, and the assertions fail on it
        # rather than on any real layout regression. `overrideredirect` takes
        # the window out of the WM's control, so the requested geometry is
        # honoured exactly -- verified 1366x768 under i3, and unchanged under
        # a bare Xvfb, which has no WM to bypass in the first place.
        root.overrideredirect(boolean=True)
        root.geometry(f"{screen_w}x{screen_h}+0+0")
        _notebook_overhead(root)
        notebook = ttk.Notebook(root)
        notebook.place(relx=0, rely=0, relwidth=1, relheight=1)
        callbacks = GateCallbacks(
            on_unit_change=_noop,
            on_submit=_noop,
            on_close=_noop,
            on_fetch_sync=_noop,
        )
        widgets = build_layout(
            notebook, _make_vars(populated=populated), callbacks, demo_mode=False
        )
        notebook.add(widgets.frame, text="Log Meal")
        # No window manager under Xvfb, so the toplevel must claim focus before
        # any FocusIn fires. Production gatelock does this via focus_force().
        root.focus_force()
        root.update()
        root.update_idletasks()

        # Reach into the viewport the layout built: the container holds the
        # canvas, whose single window item is the content frame.
        #
        # A layout with NO viewport is the case this check exists to catch, so
        # it must degrade to an accurate diagnosis rather than an exception --
        # the same measurement runs against layouts that have not been fixed
        # yet, and "StopIteration" tells the reader nothing. Without a viewport
        # the content is the container itself, the usable height is the pane,
        # and nothing scrolls.
        canvas = next(
            (
                child
                for child in widgets.frame.winfo_children()
                if isinstance(child, tk.Canvas)
            ),
            None,
        )
        if canvas is None:
            return Measurement(
                screen_w=screen_w,
                screen_h=screen_h,
                content_span=widgets.frame.winfo_reqheight(),
                viewport_h=notebook.winfo_height(),
                scrolls_by_keyboard=False,
                last_widget_visible_after_focus=False,
                has_scroll_viewport=False,
            )
        inner = canvas.winfo_children()[0]

        return _probe_viewport(root, canvas, inner, screen_w, screen_h)
    finally:
        root.destroy()
