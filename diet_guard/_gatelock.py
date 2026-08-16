"""Fullscreen "log your meals to unlock" gate window for diet_guard.

The fullscreen/grab/VT-disable/lifecycle mechanics -- an ``overrideredirect``
window with a global input grab and disabled VT switching, hardened so a
grabbed window can never become a trap (VT switching restored on every exit
path, every callback error swallowed and surfaced) -- now live in the shared
``gatelock`` package, also used by wake_alarm and screen-locker. ``MealGate``
owns a :class:`~gatelock.LockWindow` and implements
:class:`~gatelock.LockWindowHooks`.

The window walks the user through each *missing* meal slot in turn (coming home
at 17:00 backfills 08:00, then 12:00, then 16:00) and dismisses only once every
elapsed slot carries a logged meal.

Resolution is built around one idea: the macro fields plus the "per" field hold
the food's nutrition *as a reference for some amount*, and how much you ate
scales that reference into the total that is logged.  Measure by **grams** and
the reference is "per 100 g" off a label; measure by **items** and it is "per 1
item" (with the piece's approximate weight, which you can correct).  Either way
the total shown in the preview is exactly what gets recorded, and changing how
much you ate never rewrites the reference fields, so the two cannot desync.  As
you type, the picker offers your banked foods and built-in staples, so a common
food fills in one click.  Leaving the calorie field blank looks the food up
(food bank, then staples, then Open Food Facts), fills the fields, names the
source, and offers alternatives.  A running dashboard makes the day's calories
prominent, with macros and the protein target beneath.  The unlock condition is
*logging*, never *estimating correctly*: a manual calorie value always works
offline, so a dead OFF endpoint can never trap you behind the lock.

Building ``MealGate`` spans several sibling modules to keep each under the
repo's 250-line limit: :mod:`._gatelock_core` provides the shared leaf
widget/field helpers and state (``_GateCore``, ``_GateState``);
:mod:`._gatelock_nutrition` provides the reference->total nutrition maths and
food lookup (``_GateNutrition``); :mod:`._gatelock_mealflow` provides the
submit/log flow, dashboard, and callback-error handling (``_GateMealFlow``);
and :mod:`._gatelock_calendar` provides the second ``ttk.Notebook`` tab --
the budget-adherence calendar, streaks, and YTD tally from
:mod:`._daystatus`, plus budget editing (``_GateCalendar``). ``MealGate``
wires these mixins together, owns the ``gatelock.LockWindow``, and handles
construction, layout, and event binding.
"""

from __future__ import annotations

import sys
import tkinter as tk

from gatelock import (
    RANK_DIET_GUARD,
    Arbiter,
    GateRoot,
    LockConfig,
    LockWindow,
    SurfaceInfo,
)

from diet_guard._gate import due_slots
from diet_guard._gatelock_calendar import _GateCalendar, make_calendar_vars
from diet_guard._gatelock_core import _GateState
from diet_guard._gatelock_groups import GateWidgetsGroup
from diet_guard._gatelock_lockfile import acquire_gate_lock, release_gate_lock
from diet_guard._gatelock_ui import (
    GateCallbacks,
    make_vars,
)
from diet_guard._meal_schedule_store import current_schedule
from diet_guard._slots import current_slot, day_slots
from diet_guard._state import now_local

__all__ = [
    "MealGate",
    "acquire_gate_lock",
    "release_gate_lock",
]


def _assert_not_under_pytest() -> None:
    """Raise if a real Tk gate is being built inside a pytest run.

    Defence-in-depth: prevents a real fullscreen window from locking the screen
    when a test forgets to mock ``tk.Tk``.  When ``tk`` is mocked the module
    name is no longer ``tkinter``, so genuine mocked tests pass straight through.
    """
    if "pytest" in sys.modules and getattr(tk, "__name__", "") == "tkinter":
        msg = "SAFETY: MealGate built under pytest with real tkinter (tk.Tk unmocked)"
        raise RuntimeError(msg)


def _pending_slots(*, demo_mode: bool) -> list[int]:
    """Return the slots the window must collect before it can unlock.

    In production this is exactly the elapsed-but-unlogged slots.  In demo mode
    -- where there may be nothing genuinely due -- fall back to a representative
    slot so the UI is always demonstrable.

    Args:
        demo_mode: Whether the window is a safe sandbox.

    Returns:
        The slot hours to collect, ascending.
    """
    pending = list(due_slots())
    if pending:
        return pending
    if demo_mode:
        schedule = current_schedule()
        # Spelled `is None` rather than `or` because slot 0 (midnight) is
        # falsy. The two happen to be equivalent -- if 0 is a slot it is
        # necessarily the *first* slot, so both arms return 0, verified
        # exhaustively -- but the intent should not depend on that coincidence.
        elapsed = current_slot(now_local(), schedule)
        return [elapsed if elapsed is not None else day_slots(schedule)[0]]
    return []


class MealGate(_GateCalendar):
    """A fullscreen lock that dismisses only once every missing slot is logged."""

    def __init__(self, *, demo_mode: bool = True) -> None:
        """Build the lock window.

        Args:
            demo_mode: When True, use a local (not global) input grab and add a
                close button, so the gate can be exercised without locking the
                real session.  Production passes False.
        """
        _assert_not_under_pytest()
        self.demo_mode = demo_mode
        self._pending = _pending_slots(demo_mode=demo_mode)
        # All mutable logical state (provenance, suggestions, meal-in-progress)
        # lives in one bundle; see _GateState for the per-field rationale.
        self._state = _GateState()
        self.root = GateRoot()
        self.root.on_callback_error = self.on_callback_error
        self.root.title("Diet Gate" + (" [DEMO]" if demo_mode else ""))
        # No bg=/fg=/... overrides here: LockConfig's own defaults already
        # are the unified-design-system palette, and _gatelock_ui reads the
        # same LockConfig() rather than a separate hardcoded copy -- see
        # DESIGN_AUDIT_TODO.md for why an override here previously drifted.
        config = LockConfig(
            mode="soft" if demo_mode else "hard",
            app_name="diet_guard",
            rank=RANK_DIET_GUARD,
        )
        # Published here, then owned by LockWindow, which releases it on
        # close -- so deliberately not kept as an attribute.
        arbiter = Arbiter(
            "diet_guard",
            RANK_DIET_GUARD,
            grab=config.resolved_grab(),
            disable_vt=config.resolved_disable_vt(),
        )
        arbiter.publish()
        arbiter.acquire_holder()
        self._lock = LockWindow(self.root, config, hooks=self, arbiter=arbiter)
        self._vars = make_vars(self.root)
        # Built before setup(), which calls build_surface per live output.
        self._cal_vars = make_calendar_vars(self.root)
        self._cal_surfaces = []
        self._widgets = GateWidgetsGroup(self._vars)
        self._callbacks = GateCallbacks(
            on_unit_change=self._on_unit_change,
            on_submit=self._on_submit,
            on_close=self.close,
            on_fetch_sync=self._on_fetch_sync,
        )
        self._build()

    def build_surface(self, parent: tk.Misc, surface: SurfaceInfo) -> None:
        """Lay the whole gate out on one monitor.

        Called once per live output, and again whenever an output comes back.
        Every copy shares one set of GateVars, so a value typed on any screen
        is the same value on all of them and logging works from whichever
        monitor the user is actually looking at.
        """
        widgets = self._build_tabs(parent, self._callbacks)
        self._widgets.add(widgets, surface.output_name)
        # An output coming back mid-lock gets its bindings too; tk's bind
        # replaces rather than stacks, so re-wiring the others is a no-op.
        self._wire_events()

    def teardown_surface(self, surface: SurfaceInfo) -> None:
        """Forget the copy for an output that went dark."""
        self._widgets.discard(surface.output_name)
        self._cal_surfaces = self._cal_surfaces[: len(self._widgets.bundles)]

    def _build(self) -> None:
        """Lay out the UI, wire events, seed the first prompt, and grab input."""
        self._lock.setup()
        self._wire_events()
        self._relabel_basis()
        self._refresh_slot_header()
        self._refresh_dashboard()
        self._refresh_projection()
        self._refresh_calendar()
        self._lock.grab_input()
        self._widgets.desc_text.focus_set()

    def on_focus_ready(self, surface: SurfaceInfo | None) -> None:
        """Put keyboard focus on the description entry once it is mapped.

        ``surface`` is None when no output is live -- the gate is held with
        nothing to show, so there is nothing to focus.
        """
        if surface is None:
            return
        self._widgets.desc_text.focus_force()

    def on_close(self) -> None:
        """No hardware/state to release; meal-log writes already happened."""

    def close(self) -> None:
        """Restore VT switching and destroy the window (no process exit)."""
        self._lock.close()

    def run(self) -> None:
        """Run the Tk loop, restoring VT switching on every exit path."""
        self._lock.run()

    def _wire_events(self) -> None:
        """Bind the live per-keystroke events to the freshly built widgets.

        Construction-time commands (button and option-menu) are wired inside
        ``build_layout``; the key bindings that drive lookup, scaling, and
        submission are connected here, where the controller methods are in scope.
        """
        widgets = self._widgets
        widgets.desc_text.bind("<KeyRelease>", self._on_desc_keyrelease)
        widgets.desc_text.bind("<Return>", self._on_desc_return)
        widgets.suggestion_box.bind(
            "<<ListboxSelect>>",
            self._on_suggestion_select,
        )
        for entry in (widgets.amount_entry, widgets.per_entry):
            entry.bind("<KeyRelease>", self._on_amount_change)
            entry.bind("<Return>", self._on_return)
        for entry in self._macro_entries():
            entry.bind("<Return>", self._on_return)
            entry.bind("<KeyRelease>", self._on_macro_edit)

    def _on_desc_return(self, _event: tk.Event[tk.Misc]) -> str:
        """Submit on Enter in the description box, suppressing the newline."""
        self._on_submit()
        return "break"
