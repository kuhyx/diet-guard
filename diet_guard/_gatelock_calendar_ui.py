"""``ttk`` theming for the gate's History tab, and its public surface.

Split across three modules to keep each under the repo's 250-line limit:
:mod:`._gatelock_calendar_types` holds the data bundles, constants and
palette, :mod:`._gatelock_calendar_widgets` builds the widgets, and this
module owns the ``ttk.Notebook`` theming.

Everything the tab's controller (:mod:`._gatelock_calendar`) needs is
re-exported here, because that module already imports all seven names from
this one.  The ``ttk`` import is also load-bearing beyond theming: the test
suite patches ``_gatelock_calendar_ui.ttk`` with a fake, so this module must
keep binding ``ttk`` at module level.
"""

from __future__ import annotations

from tkinter import ttk
from typing import TYPE_CHECKING

from diet_guard._gatelock_calendar_types import (
    _ACCENT,
    _COLORS,
    _DECEMBER,
    _DEFAULT_BUDGET_KCAL,
    _FIELD_BG,
    _JANUARY,
    _MONTH_AFTER_DECEMBER,
    CalendarCallbacks,
    CalendarVars,
    CalendarWidgets,
    make_calendar_vars,
)
from diet_guard._gatelock_calendar_widgets import build_calendar_frame
from diet_guard._gatelock_spacing import MD, SM
from diet_guard._gatelock_ui import BG, FG

if TYPE_CHECKING:
    import tkinter as tk

__all__ = [
    "_DECEMBER",
    "_DEFAULT_BUDGET_KCAL",
    "_JANUARY",
    "_MONTH_AFTER_DECEMBER",
    "CalendarCallbacks",
    "CalendarVars",
    "CalendarWidgets",
    "_style_notebook",
    "build_calendar_frame",
    "make_calendar_vars",
]


def _style_notebook(root: tk.Misc) -> None:
    """Theme the ``ttk.Notebook`` tab strip to match the gate's dark palette.

    ``ttk`` widgets ignore plain ``bg=``/``fg=`` -- unlike every other widget
    here, they only take color from a named ``ttk.Style``. Without this the
    tab strip renders in the OS's default (light) ttk theme regardless of how
    dark the rest of the gate is. ``clam`` is used because it is the ttk
    theme that reliably honors ``.configure()`` overrides cross-platform; the
    built-in ``default``/``alt`` themes on some platforms ignore custom tab
    colors.
    """
    style = ttk.Style(root)
    style.theme_use("clam")
    style.configure("TNotebook", background=BG, borderwidth=0)
    style.configure(
        "TNotebook.Tab",
        background=_FIELD_BG,
        foreground=FG,
        padding=(MD, SM),
        borderwidth=0,
    )
    style.map(
        "TNotebook.Tab",
        background=[("selected", _ACCENT)],
        foreground=[("selected", _COLORS.on_fill)],
    )
