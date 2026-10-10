"""The lock screen's "Fill all" button: today's catering into every empty slot.

Two clicks, never one. The first fetches the day's delivery off the Tk thread
and shows exactly what would be written; the button relabels to "Confirm (N)".
Only the second click writes. A delivered meal is not an eaten meal, so the
user sees the dishes and the slots before anything lands -- and no modal
dialog asks instead, because a pop-up over a fullscreen grab risks stealing the
very keyboard grab the lock depends on.

This is *composed* into the gate rather than mixed in: pylint's
``max-parents`` already counts every class in the gate's MRO, so a new mixin
fails the hook, and module functions reaching into the gate trip ``SLF001``.
The gate hands this object the few callables it needs instead.

Which slots get filled -- every slot today, skipping any that already holds an
entry -- is :func:`diet_guard._kuchnia_log.fill_plan`, shared with
``diet-guard kuchnia --log`` so the CLI and the gate cannot disagree.
"""

from __future__ import annotations

from importlib import import_module
import queue
from typing import TYPE_CHECKING, NamedTuple

from diet_guard._gatelock_fetch import FETCH_POLL_MS
from diet_guard._gatelock_kuchnia import start_delivery_fetch
from diet_guard._kuchnia_log import fill_plan, log_dishes
from diet_guard._kuchnia_spread import assign_slots
from diet_guard._meal_schedule_store import current_schedule
from diet_guard._slots import day_slots, slot_label
from diet_guard._state import now_local

if TYPE_CHECKING:  # pragma: no cover - typing only
    from collections.abc import Callable, Sequence
    from datetime import date
    import tkinter as tk

    from diet_guard._gatelock_kuchnia import DeliveryResult, RefreshFn
    from diet_guard._kuchnia_parse import Dish
    from diet_guard._kuchnia_spread import SlottedDish

#: The button's resting label; also what it returns to after each attempt.
FILL_LABEL = "🍱 Fill all"

#: ``(unlock reason, nothing-new status)`` for the gate's post-write reconcile:
#: a fill that covered only later slots must not report "found in sync".
RECONCILE_LABELS = (
    "Filled from catering",
    "Catering logged; this slot still needs a meal.",
)


def _refresh_delivery(day: date) -> tuple[Sequence[Dish], str | None]:
    """Fetch ``day``'s dishes, importing the HTTP stack only when clicked.

    ``_kuchnia_import`` reaches ``requests``; the gate's frequent not-due tick
    imports this module and must not pay for it.
    """
    refresh: RefreshFn = import_module("diet_guard._kuchnia_import").refresh_delivery
    return refresh(day)


class FillHooks(NamedTuple):
    """What the flow calls back into the gate."""

    #: The gate's status-line writer.
    set_status: Callable[..., None]
    #: Called after a write, so the gate drops the slots it now covers and
    #: unlocks when none remain.
    on_logged: Callable[[], None]


class FillAllFlow:
    """Drives one gate's "Fill all" button through fetch, confirm and log."""

    def __init__(
        self,
        root: tk.Misc,
        label: tk.StringVar,
        hooks: FillHooks,
        *,
        demo_mode: bool,
    ) -> None:
        """Bind the flow to a gate.

        Args:
            root: Schedules the poll on the Tk thread.
            label: The button's text, shared by its copy on every monitor.
            hooks: The gate callbacks the flow drives.
            demo_mode: A demo window refuses: it must never write real
                entries from a delivery note.
        """
        self._root = root
        self._label = label
        self._demo_mode = demo_mode
        self._set_status = hooks.set_status
        self._on_logged = hooks.on_logged
        self._result: queue.Queue[DeliveryResult] | None = None
        self._plan: list[SlottedDish] = []
        self._plan_day: date | None = None

    def click(self) -> None:
        """First click fetches and proposes; a second click confirms."""
        if self._demo_mode:
            self._set_status("Fill all is only available on the real lock.")
            return
        if self._result is not None:
            return  # a fetch is in flight; a double-click must not start two
        today = now_local().date()
        if self._plan and self._plan_day == today:
            self._confirm()
            return
        # No plan, or one proposed before midnight: fetch (again). The day is
        # pinned here, not when the result lands, so a fetch still in flight
        # at midnight can never confirm yesterday's menu into today.
        self._reset()
        self._plan_day = today
        self._set_status("Loading today's delivery…")
        self._result = start_delivery_fetch(_refresh_delivery, today)
        self._root.after(FETCH_POLL_MS, self._poll)

    def _poll(self) -> None:
        """On the Tk thread: turn the fetched dishes into a proposal."""
        result = self._result
        if result is None:
            return
        try:
            outcome = result.get_nowait()
        except queue.Empty:
            self._root.after(FETCH_POLL_MS, self._poll)
            return
        self._result = None
        if outcome.reason is not None:
            self._set_status(f"{outcome.reason} — still locked.", error=True)
            return
        if not outcome.dishes:
            self._set_status("No catering delivery today.")
            return
        plan = fill_plan(assign_slots(outcome.dishes, day_slots(current_schedule())))
        if not plan:
            self._set_status("Every slot already has a meal — nothing to fill.")
            return
        self._plan = plan
        self._label.set(f"✓ Confirm ({len(plan)})")
        total = sum(item.dish.kcal for item in plan)
        listing = ", ".join(
            f"{slot_label(item.slot)} {item.dish.name}" for item in plan
        )
        self._set_status(
            f"Will log {len(plan)} ({total:g} kcal): {listing} — click Confirm."
        )

    def _confirm(self) -> None:
        """Write the proposed dishes into the slots still empty right now."""
        # Re-checked at write time: a meal typed in between the two clicks
        # has taken its slot, and must keep it.
        plan = fill_plan(self._plan)
        self._reset()
        if not plan:
            self._set_status("Every slot already has a meal — nothing to fill.")
            return
        written = log_dishes(plan)
        self._set_status(f"Logged {len(written)} catering dish(es).")
        self._on_logged()

    def _reset(self) -> None:
        """Forget any proposal and restore the button's label."""
        self._plan = []
        self._plan_day = None
        self._label.set(FILL_LABEL)
