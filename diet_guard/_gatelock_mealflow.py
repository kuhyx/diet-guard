"""Submit/record flow for the MealGate gate.

Split out of :mod:`._gatelock` to keep that module under the repo's 250-line
limit.  ``_GateMealFlow`` extends
:class:`~diet_guard._gatelock_dashboard._GateDashboard` (itself over
:class:`~diet_guard._gatelock_nutrition._GateNutrition`) with the
submit/lookup/log flow and the per-slot input reset.  The read-only
calorie/macro dashboard it calls into lives in :mod:`._gatelock_dashboard`.
"""

from __future__ import annotations

import contextlib
import queue
import tkinter as tk
from typing import TYPE_CHECKING

from diet_guard._foodbank import remember_food
from diet_guard._gate import due_slots
from diet_guard._gatelock_dashboard import _GateDashboard
from diet_guard._gatelock_fetch import FETCH_POLL_MS, start_fetch
from diet_guard._gatelock_ui import ERR, FG, UNIT_GRAMS
from diet_guard._resolve import lookup_candidates
from diet_guard._slots import slot_label
from diet_guard._state import log_meal
from diet_guard._sync_refresh import pull_peer_logs

if TYPE_CHECKING:
    from diet_guard._estimator import Nutrition

# How long the "unlocking..." confirmation lingers before the window tears down.
_UNLOCK_DELAY_MS = 1200


class _GateMealFlow(_GateDashboard):
    """Submit/lookup/log flow for a logged food."""

    #: The in-flight fetch's result queue, or None when no fetch is running.
    #: Doubles as the poll's own guard: a stray poll after completion finds
    #: None and stops rather than blocking on an empty queue forever.
    _fetch_result: queue.Queue[str | None] | None = None

    # -- slot walk ------------------------------------------------------------

    def _clear_inputs(self) -> None:
        """Empty the food fields, picker, preview, and basis for a new slot."""
        self._set_desc("")
        self._widgets.amount_entry.delete(0, tk.END)
        self._vars.unit.set(UNIT_GRAMS)
        self._relabel_basis()
        self._reset_per_default()
        for entry in self._macro_entries():
            entry.delete(0, tk.END)
        self._widgets.suggestion_box.delete(0, tk.END)
        self._state.suggestions = []
        self._state.source = "manual"
        self._state.last_reference = None
        self._vars.preview.set("")
        self._refresh_projection()

    # -- behaviour ------------------------------------------------------------

    def _set_status(self, text: str, *, error: bool = False) -> None:
        """Update the status line, red for errors."""
        self._vars.status.set(text)
        self._widgets.status_label.config(fg=ERR if error else FG)

    def _on_return(self, _event: tk.Event[tk.Misc]) -> None:
        """Handle the Enter key in any entry field."""
        self._on_submit()

    def _on_submit(self) -> None:
        """Validate, then look the food up, or log it."""
        description = self._get_desc()
        if not description:
            self._set_status("Type what you ate first.", error=True)
            self._widgets.desc_text.focus_set()
            return

        values = self._macro_values()
        if values is None:
            self._set_status("Macros must be numbers.", error=True)
            self._widgets.macros.kcal.focus_set()
            return

        if values[0] is None:
            self._begin_lookup(description)
            return
        nutrition = self._current_nutrition()
        if nutrition is None:
            self._set_status("Enter the calories, then submit.", error=True)
            self._widgets.macros.kcal.focus_set()
            return
        self._record(description, nutrition)

    def _begin_lookup(self, description: str) -> None:
        """Step 1: look the food up, fill the label fields, offer alternatives.

        Nothing is logged here -- the user must see and confirm the filled
        values (a second submit) before they are recorded.  The food is looked
        up at its natural basis (per 100 g / serving); the amount eaten scales
        it, so the lookup never bakes in a portion.
        """
        self._set_status("looking up…")
        self.root.update_idletasks()
        candidates = lookup_candidates(description)
        if not candidates:
            self._set_status(
                "Couldn't look that up. Enter the calories yourself, then submit.",
                error=True,
            )
            self._widgets.macros.kcal.focus_set()
            return
        self._show_candidates(candidates)
        self._apply_reference(candidates[0][1])
        source = candidates[0][1].source
        tail = (
            "Review, or pick another below, then submit to log."
            if len(candidates) > 1
            else "Review the values, then submit to log."
        )
        self._set_status(f"Filled from {source}. {tail}")

    def _record(self, description: str, nutrition: Nutrition) -> None:
        """Log and bank a single food for the current slot, then advance."""
        log_meal(description, nutrition, self._slot_for_log())
        remember_food(description, nutrition)
        self._finish_slot(f"{nutrition.kcal:g} kcal ({nutrition.source})")

    def _slot_for_log(self) -> int | None:
        """Return the slot to tag a log with -- None in demo (satisfies no slot).

        A synthetic demo slot must never satisfy a real checkpoint, so demo logs
        are slot-less: they still bank the food and update the dashboard, but do
        not silently stop the production gate from firing.
        """
        return None if self.demo_mode else self._pending[0]

    def _finish_slot(self, summary: str) -> None:
        """Advance past the current slot after something was logged for it.

        Args:
            summary: A short description of what was logged (calories and
                source), shown in the confirmation line.
        """
        slot = self._pending[0]
        self._pending.pop(0)
        self._refresh_dashboard()
        logged = f"Logged {slot_label(slot)}: {summary}"
        if not self._pending:
            self._unlock(logged)
            return
        self._clear_inputs()
        self._refresh_slot_header()
        self._set_status(f"{logged} — next meal, please.")
        self._widgets.desc_text.focus_set()

    def _unlock(self, logged: str) -> None:
        """Confirm the final log and tear the window down.

        Teardown is scheduled *before* the budget is looked up, so a corrupt
        budget file (which raises) can never re-trap the user at unlock time.
        """
        self._set_status(f"{logged} — all meals logged, unlocking…")
        self.root.after(_UNLOCK_DELAY_MS, self.close)

    # -- manual sync ------------------------------------------------------------

    def _on_fetch_sync(self) -> None:
        """Pull the shared log on demand and unlock any slots it now satisfies.

        For a meal already logged on another device (typically the phone) that
        has not yet propagated here: rather than re-entering it to unlock, the
        user pulls it in.

        The pull is the *narrow* one (:func:`pull_peer_logs`) and runs on a
        worker thread, so the window stays live. It used to run the full tick
        inline and froze the fullscreen lock for its whole duration (~18-27s
        measured). The button's question is the same as the gate's -- "did a
        peer log this slot?" -- and :meth:`_reconcile_after_fetch` reads only
        ``due_slots()``, so the budget and food banks it dropped were never
        consulted here; the full tick still runs once the window closes.
        Measured at ~92ms against the live remote.

        Fails closed: a failure leaves the lock untouched. A second click while
        a fetch is in flight is ignored, which is the reentrancy guard and the
        write-race fix in one -- two workers would race two log writes and
        orphan one result.
        """
        if self.demo_mode:
            self._set_status("Fetch from sync is only available on the real lock.")
            return
        if self._fetch_result is not None:
            # Already fetching. Without this a double-click starts a second
            # worker, orphans the first result and races two log writes.
            return
        self._set_status("Fetching from sync…")
        self._fetch_result = start_fetch(pull_peer_logs)
        self.root.after(FETCH_POLL_MS, self._poll_fetch)

    def _poll_fetch(self) -> None:
        """On the Tk thread: pick up the worker's result once it lands."""
        result = self._fetch_result
        if result is None:
            return
        try:
            reason = result.get_nowait()
        except queue.Empty:
            self.root.after(FETCH_POLL_MS, self._poll_fetch)
            return
        self._fetch_result = None
        if reason is not None:
            self._set_status(f"{reason} — still locked.", error=True)
            return
        self._reconcile_after_fetch()

    def _reconcile_after_fetch(self) -> None:
        """Drop pending slots a freshly pulled meal now covers; unlock if none."""
        still_due = set(due_slots())
        satisfied_slots = [slot for slot in self._pending if slot not in still_due]
        self._refresh_dashboard()
        if not satisfied_slots:
            self._set_status("No new meals found in sync.")
            return
        self._pending = [slot for slot in self._pending if slot in still_due]
        if not self._pending:
            self._unlock("Synced from another device")
            return
        self._clear_inputs()
        self._refresh_slot_header()
        count = len(satisfied_slots)
        meal_word = "meal" if count == 1 else "meals"
        self._set_status(f"Pulled {count} {meal_word} — next meal, please.")
        self._widgets.desc_text.focus_set()

    def on_callback_error(self) -> None:
        """Surface an unexpected callback error without dropping the grab."""
        self._set_status(
            "Something went wrong. Enter the calories, then submit again.",
            error=True,
        )
        with contextlib.suppress(tk.TclError):
            self._widgets.macros.kcal.focus_set()
