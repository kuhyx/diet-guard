"""Focus-reachability probing for the gate layout measurement.

Split out of :mod:`._gate_layout_probe` to keep both files under the repo's
250-line limit.  That module builds the layout and owns the
:class:`Measurement` result; this one interrogates a built viewport -- does it
scroll by keyboard, and does the view follow focus to the *bottom* of the
content, where the submit button and dashboard live.

Test support, not a test, for the same reason as its sibling: its
diagnostic-only branches are not held to the package's 100%-coverage bar.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from diet_guard.tests._gate_measurement import Measurement

if TYPE_CHECKING:
    import tkinter as tk

# Tk widget classes that take keyboard focus by default. Checking `takefocus`
# is not enough: it is "" on most widgets, meaning "ask ::tk::FocusOK", so an
# empty value indicates a *default*-focusable widget rather than an opted-out
# one. Matching on class is what actually mirrors FocusOK's behaviour here.
_FOCUSABLE_CLASSES = frozenset(
    {
        "Button",
        "Checkbutton",
        "Entry",
        "Listbox",
        "Radiobutton",
        "Spinbox",
        "Text",
    }
)


def _is_focusable(widget: tk.Misc) -> bool:
    """Whether ``widget`` would accept keyboard focus."""
    if str(widget.cget("takefocus")) == "0":
        return False
    if str(widget.cget("takefocus")) == "1":
        return True
    return widget.winfo_class() in _FOCUSABLE_CLASSES


def _deepest_focusable(widget: tk.Misc) -> tk.Misc | None:
    """Return the last descendant that can take keyboard focus.

    Used to prove the *bottom* of the content is reachable, which is where the
    submit button and the dashboard live -- exactly what a centered, clipping
    frame used to hide.
    """
    found: tk.Misc | None = None
    for child in widget.winfo_children():
        if _is_focusable(child):
            found = child
        deeper = _deepest_focusable(child)
        if deeper is not None:
            found = deeper
    return found


def _probe_viewport(
    root: tk.Misc,
    canvas: tk.Canvas,
    inner: tk.Misc,
    screen_w: int,
    screen_h: int,
) -> Measurement:
    """Interrogate a built viewport: does it scroll, and does focus follow?

    Split out of :func:`measure` so each function does one thing -- building the
    layout, and interrogating it -- and so neither trips the local-variable cap.
    """
    box = canvas.bbox("all")
    span = (box[3] - box[1]) if box else 0
    viewport_h = canvas.winfo_height()

    canvas.yview_moveto(0.0)
    root.update_idletasks()
    canvas.yview_scroll(1, "pages")
    root.update_idletasks()
    scrolls = canvas.yview()[0] > 0.0

    # Scroll back to the top, then focus the deepest widget and check it ends up
    # on screen. Starting from the top is what makes this a real test: it is the
    # state a user arrives in.
    canvas.yview_moveto(0.0)
    root.update_idletasks()
    target = _deepest_focusable(inner)
    last_visible = False
    if target is not None:
        # A real keypress first, then the focus it would have moved. Since
        # 2026-08-03 gatelock only scrolls to follow focus the *user* moved:
        # it used to follow programmatic focus too, and because the apps
        # re-focus a widget on every repaint, the screen scrolled itself to
        # mid-content and back while the user was doing nothing. A bare
        # focus_set() here would therefore test a path no user can take.
        target.event_generate("<Key-Tab>", when="now")
        target.focus_set()
        root.update()
        root.update_idletasks()
        top = target.winfo_rooty() - inner.winfo_rooty()
        visible_from = canvas.canvasy(0)
        last_visible = visible_from <= top <= visible_from + viewport_h

    return Measurement(
        screen_w=screen_w,
        screen_h=screen_h,
        content_span=span,
        viewport_h=viewport_h,
        scrolls_by_keyboard=scrolls,
        last_widget_visible_after_focus=last_visible,
    )
