"""The lock screen's two "pull it in from elsewhere" flows.

Both let the user satisfy a slot without retyping a meal, and both run their
network call off the Tk thread: **Fetch from sync** for a meal a peer already
logged, and **Today's delivery** for the day's catering.

A mixin on :class:`~diet_guard._gatelock_mealflow._GateMealFlow` rather than a
link in the controller chain -- pylint caps that chain's depth and the gate is
at the limit -- and a separate module so both stay under the 250-line cap.

**Neither logs anything by itself.** The catering fetch fills the form and
stops; the user still clicks "Log & Continue". Auto-submitting would let the
gate satisfy its own checkpoint from a delivery note, which is the one thing
this feature is designed not to do.
"""

from __future__ import annotations

from importlib import import_module
import queue
import sys
from typing import TYPE_CHECKING

from diet_guard._gate import due_slots
from diet_guard._gatelock_fetch import FETCH_POLL_MS, start_fetch
from diet_guard._gatelock_kuchnia import start_delivery_fetch
from diet_guard._gatelock_nutrition import _GateNutrition
from diet_guard._kuchnia_spread import dish_field_values, dishes_in_slot_order
from diet_guard._state import now_local
from diet_guard._sync_refresh import pull_peer_logs

if TYPE_CHECKING:  # pragma: no cover - typing only
    from collections.abc import Callable

    from diet_guard._gatelock_kuchnia import DeliveryResult
    from diet_guard._kuchnia_parse import Dish

# ``_kuchnia_import`` reaches ``requests``. The gate's far more common not-due
# tick imports this module and must not pay ~78ms for an HTTP stack it never
# touches, so the name resolves on first access -- the same PEP 562 hook
# ``_cli_gate`` and ``_cli_prune`` use, which also keeps ``patch.object`` working.
_LAZY_ATTRS = ("refresh_delivery", "refresh_delivery_once")


def __getattr__(name: str) -> object:
    """Resolve the deferred catering import on first attribute access."""
    if name not in _LAZY_ATTRS:
        msg = f"module {__name__!r} has no attribute {name!r}"
        raise AttributeError(msg)
    return getattr(import_module("diet_guard._kuchnia_import"), name)


class _PullFlows(_GateNutrition):
    """The lock screen's two "pull it in from elsewhere" buttons.

    Both let the user satisfy a slot without retyping a meal, and both run
    their network call off the Tk thread. One mixin rather than two because
    pylint caps the controller chain's depth and every MRO entry counts.
    """

    #: Slots still to be filled. Declared on the controller this mixin is
    #: mixed into; repeated here so mypy can type the reconcile below.
    _pending: list[int]

    #: The in-flight sync fetch's queue, or None when none is running.
    #: Doubles as the poll's own guard: a stray poll after completion finds
    #: None and stops rather than blocking on an empty queue forever.
    _fetch_result: queue.Queue[str | None] | None = None

    #: The in-flight catering fetch's queue, or None when none is running.
    _delivery_result: queue.Queue[DeliveryResult] | None = None

    #: Dishes fetched but not yet offered, in slot order. Popped one at a
    #: time so each still passes through the normal submit path.
    _delivery_pending: tuple[Dish, ...] = ()

    #: True when the running fetch came from the button rather than the
    #: window opening. An automatic fetch must not talk over the gate's own
    #: prompt to report that the caterer had nothing today.
    _delivery_asked: bool = False

    #: The in-flight sync fetch's queue, or None when none is running.

    #: Slots still to be filled; owned by the controller this mixes into.

    # Supplied by ``_GateMealFlow``, which mixes this class in. Declared so the
    # contract is explicit and pylint can see it: the dependency runs both ways
    # (the flows drive the meal form, the form hosts the flows) and the
    # ancestor cap leaves no room for another chain link.
    _set_status: Callable[..., None]
    _clear_inputs: Callable[[], None]
    _refresh_dashboard: Callable[[], None]
    _unlock: Callable[[str], None]

    # -- catering delivery ------------------------------------------------------

    def _on_load_delivery(self) -> None:
        """Fetch today's catering and offer it as prefilled entries.

        Refuses in demo mode: a synthetic window must never satisfy a real
        checkpoint, and there is no reason to send real credentials from one.
        Fails closed -- any failure leaves the lock exactly as it was, and a
        second click while a fetch is in flight is ignored.
        """
        if self.demo_mode:
            self._set_status("Loading a delivery is only available on the real lock.")
            return
        if self._delivery_result is not None:
            return
        self._delivery_asked = True
        self._set_status("Loading today's delivery…")
        # Through the module object so the lazy hook resolves it, and so a
        # test's ``patch.object`` still wins.
        self._delivery_result = start_delivery_fetch(
            sys.modules[__name__].refresh_delivery,
            now_local().date(),
        )
        self.root.after(FETCH_POLL_MS, self._poll_delivery)

    def _poll_delivery(self) -> None:
        """On the Tk thread: pick up the catering worker's result."""
        result = self._delivery_result
        if result is None:
            return
        try:
            outcome = result.get_nowait()
        except queue.Empty:
            self.root.after(FETCH_POLL_MS, self._poll_delivery)
            return
        self._delivery_result = None
        if outcome.reason is not None:
            if self._delivery_asked:
                self._set_status(f"{outcome.reason} — still locked.", error=True)
            return
        if not outcome.dishes:
            if self._delivery_asked:
                self._set_status("No catering delivery today.")
            return
        self._delivery_pending = dishes_in_slot_order(outcome.dishes)
        self._prefill_next_dish()

    def _prefill_next_dish(self) -> None:
        """Fill the form from the next queued dish, if there is one."""
        if not self._delivery_pending:
            return
        dish, *rest = self._delivery_pending
        self._delivery_pending = tuple(rest)
        self._clear_inputs()
        self._set_desc(dish.name)
        grams, macros = dish_field_values(dish)
        self._widgets.amount_entry.insert(0, grams)
        for entry, value in zip(self._macro_entries(), macros, strict=True):
            entry.insert(0, value)
        self._state.source = "kuchnia wikinga"
        self._refresh_projection()
        remaining = len(self._delivery_pending)
        suffix = f" ({remaining} more to go)" if remaining else ""
        self._set_status(f"Loaded: {dish.name}{suffix} — check, then Log & Continue.")

    def _autoload_delivery(self) -> None:
        """Start a guarded catering fetch as the lock opens.

        The user is stopped anyway, so the dishes are waiting by the time they
        reach for them and the spinner sits *inside* the lock. Deliberately not
        in ``_cli_gate._should_lock``: ``gate_is_due()`` never reads the food
        bank, so a refresh there could not change the lock decision while
        adding a third-party round trip to the ~105ms ``gate --check`` path.

        Silent by design -- an outage must not greet the user the moment the
        window appears, and the button is still there to retry.
        """
        if self.demo_mode or self._delivery_result is not None:
            return
        self._delivery_asked = False
        self._delivery_result = start_delivery_fetch(
            sys.modules[__name__].refresh_delivery_once,
            now_local().date(),
        )
        self.root.after(FETCH_POLL_MS, self._poll_delivery)

    # -- manual sync ------------------------------------------------------------

    def _on_fetch_sync(self) -> None:
        """Pull the shared log on demand and unlock any slots it now satisfies.

        For a meal already logged on another device (typically the phone) that
        has not propagated here yet: rather than re-entering it to unlock, the
        user pulls it in.

        The pull is the *narrow* one (:func:`pull_peer_logs`) and runs on a
        worker thread -- inline it froze the fullscreen lock for ~18-27s. See
        ``docs/sync-latency.md``. Fails closed, and a second click while a
        fetch is in flight is ignored: that is the reentrancy guard and the
        write-race fix in one.
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
        """Drop slots a pulled meal now covers; unlock when none remain."""
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
