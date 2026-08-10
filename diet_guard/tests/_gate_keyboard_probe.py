"""Walk the gate's real focus ring and report keyboard reachability.

Reading the code is not enough to know what is reachable: Tk decides via
``::tk::FocusOK``, which consults ``takefocus``, mapped-ness, *and* whether the
widget's class has any key bindings at all. A ``tk.Canvas`` fails that last test
even though it looks like a normal widget, and a ``Menubutton`` fails the first.
So this walks ``tk_focusNext`` the way the Tab key does.

There is deliberately no ``print``-based CLI: ruff runs with
``--unsafe-fixes``, whose ``T201`` fix *deletes* print statements, silently
turning a diagnostic script into a no-op. :func:`probe` is consumed by
``tests/test_gatelock_keyboard.py``, which fails rather than reports.

Test support, not a test: it lives under ``tests/`` and is excluded from the
``test_*.py`` naming hook.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import tkinter as tk
from tkinter import ttk

from diet_guard._gatelock_ui import GateCallbacks, build_layout
from diet_guard.tests._gate_layout_probe import _make_vars, _noop

# How far to walk before declaring the ring non-terminating.
_MAX_RING_STEPS = 60


@dataclass
class RingReport:
    """What a focus-ring walk found."""

    classes: list[str] = field(default_factory=list)
    focus_rings_visible: dict[str, str] = field(default_factory=dict)
    text_escapes_tab: bool = False
    buttons_take_return: bool = False

    def has(self, widget_class: str) -> bool:
        """Whether the ring includes at least one widget of this class."""
        return widget_class in self.classes

    def describe(self) -> str:
        """Return a multi-line human-readable summary."""
        lines = [f"focus ring ({len(self.classes)} stops):"]
        lines.append("  " + " -> ".join(self.classes) + " -> (wrap)")
        lines.append("focus-ring colors by class:")
        for name, color in sorted(self.focus_rings_visible.items()):
            verdict = (
                "visible"
                if color.lower() not in {"", "#000000", "black"}
                else "INVISIBLE"
            )
            lines.append(f"  {name:<12} highlightcolor={color or '<unset>'}  {verdict}")
        lines.append(f"Text escapes Tab      : {self.text_escapes_tab}")
        lines.append(f"Buttons accept Return : {self.buttons_take_return}")
        return "\n".join(lines)


def _walk_ring(start: tk.Misc, limit: int = _MAX_RING_STEPS) -> list[tk.Misc]:
    """Return the widgets Tab visits, starting from ``start``, until it wraps."""
    seen: list[tk.Misc] = []
    current = start
    for _ in range(limit):
        if current in seen:
            break
        seen.append(current)
        current = current.tk_focusNext()
        if current is None:
            break
    return seen


def probe(screen_w: int = 1366, screen_h: int = 768) -> RingReport:
    """Build the gate and probe its keyboard behaviour."""
    root = tk.Tk()
    try:
        # Bypass the window manager -- see the same call in
        # `_gate_layout_probe.measure`. A tiling WM retiles this toplevel
        # instead of honouring the geometry, the widgets never realize at a
        # usable size, and the focus ring then walks a single stop, failing
        # every traversal assertion for reasons that have nothing to do with
        # the focus order under test.
        root.overrideredirect(boolean=True)
        root.geometry(f"{screen_w}x{screen_h}+0+0")
        notebook = ttk.Notebook(root)
        notebook.place(relx=0, rely=0, relwidth=1, relheight=1)
        callbacks = GateCallbacks(
            on_unit_change=_noop,
            on_submit=_noop,
            on_close=_noop,
            on_fetch_sync=_noop,
        )
        widgets = build_layout(
            notebook, _make_vars(populated=True), callbacks, demo_mode=False
        )
        notebook.add(widgets.frame, text="Log Meal")
        notebook.enable_traversal()
        root.focus_force()
        root.update()
        root.update_idletasks()

        report = RingReport()
        ring = _walk_ring(widgets.desc_text)
        for widget in ring:
            report.classes.append(widget.winfo_class())
            try:
                color = str(widget.cget("highlightcolor"))
            except tk.TclError:
                continue
            report.focus_rings_visible.setdefault(widget.winfo_class(), color)

        # Tab out of the description box: it must not stay focused.
        widgets.desc_text.focus_set()
        root.update()
        widgets.desc_text.event_generate("<Tab>")
        root.update()
        root.update_idletasks()
        report.text_escapes_tab = root.focus_get() is not widgets.desc_text

        # Return must invoke a button (Tk binds only <space> on X11).
        fired: list[str] = []
        probe_button = next(
            (w for w in ring if isinstance(w, tk.Button)),
            None,
        )
        if probe_button is not None:
            probe_button.configure(command=lambda: fired.append("hit"))
            probe_button.focus_set()
            root.update()
            probe_button.event_generate("<Return>")
            root.update()
            root.update_idletasks()
        report.buttons_take_return = bool(fired)
        return report
    finally:
        root.destroy()
