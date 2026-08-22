"""The gate's data bundles: its variables, widgets, and callbacks.

Split out of ``_gatelock_ui`` (and re-exported from it) so neither module
exceeds the repo's 500-line limit. Nothing here builds a widget; these are
the shapes the layout returns and the controller drives.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable
    import tkinter as tk


@dataclass
class _MacroEntries:
    """The four macro entry widgets, in (kcal, protein, carbs, fat) order."""

    kcal: tk.Entry
    protein: tk.Entry
    carbs: tk.Entry
    fat: tk.Entry


@dataclass
class GateEntryVars:
    """The variables behind the gate's typed-in fields.

    Since gatelock v0.2.0 the gate is laid out once per live output, so every
    entry is bound to one of these: typing an amount on whichever screen the
    user is looking at is the same value on all of them, and reading it back
    needs no idea which monitor that was.
    """

    amount: tk.StringVar
    per: tk.StringVar
    kcal: tk.StringVar
    protein: tk.StringVar
    carbs: tk.StringVar
    fat: tk.StringVar


@dataclass
class GateVars:
    """Tk string variables bound to the gate's live, auto-updating fields."""

    status: tk.StringVar
    slot_header: tk.StringVar
    preview: tk.StringVar
    projection: tk.StringVar
    cal_headline: tk.StringVar
    dashboard: tk.StringVar
    unit: tk.StringVar
    entries: GateEntryVars


@dataclass
class GateWidgets:
    """Interactive widgets the controller reads back after the UI is built."""

    frame: tk.Frame
    desc_text: tk.Text
    amount_entry: tk.Entry
    per_entry: tk.Entry
    basis_prefix: tk.Label
    macros: _MacroEntries
    suggestion_box: tk.Listbox
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
    on_fetch_sync: Callable[[], None]
    on_load_delivery: Callable[[], None]
