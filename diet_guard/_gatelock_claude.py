"""The lock screen's Claude button: estimate the typed meal, log it, unlock.

The user types a description and presses the sparkle instead of filling the
macro fields. The text (never a photo, the PC has none) goes to
:func:`diet_guard._claude_estimate.estimate_meal`; on success the meal is
logged through the gate's own ``record`` hook, so it takes the same path as a
typed meal: the slot being locked for, the food bank, the dashboard, the
unlock. Its entry carries ``source="claude"``.

**It can never make the lock worse.** Four rules, each with a test:

* *Off the Tk thread.* The call runs on a daemon thread that only ``put``s on
  a queue; the Tk thread polls it with ``after`` (Tcl is not thread-safe, and
  a model call takes seconds). A daemon so a hung call cannot keep the
  ``Type=oneshot`` unit alive once the window is gone.
* *A hard 45 s deadline* on the poll, whatever the worker does. Past it the
  result is abandoned and a late answer is discarded.
* *Any failure is an icon, nothing else.* No login, timeout, bad JSON, a bug:
  the button shows the error icon and the manual log path is untouched. There
  is no state in which a failed estimate unlocks, blocks or freezes anything.
* *A result for a slot that moved on is dropped*: if the user logged the slot
  by hand while Claude thought, the answer must not land on the next one.

Composed into the gate (as ``FillAllFlow`` is) rather than mixed in: pylint's
``max-parents`` counts every class in the gate's MRO and the chain is at the
cap. The gate hands this object the few callables it needs.

``_claude_estimate`` reaches the Agent SDK, which the gate's frequent not-due
tick must not import, so the name resolves on first access (PEP 562) and a
test's ``patch.object`` still wins.
"""

from __future__ import annotations

from contextlib import suppress
from importlib import import_module
import queue
import sys
import threading
from time import monotonic
from typing import TYPE_CHECKING, NamedTuple

from diet_guard import _gatelock_glyphs as g
from diet_guard._estimator import Nutrition
from diet_guard._gatelock_fetch import FETCH_POLL_MS

if TYPE_CHECKING:  # pragma: no cover - typing only
    from collections.abc import Callable
    import tkinter as tk

    from diet_guard._claude_schema import Estimate

#: The poll's hard deadline in seconds; the estimator's own budget matches it.
CLAUDE_TIMEOUT_S = 45.0

#: Polls between spinner frames (50 ms each).
_FRAME_TICKS = 4

#: ``Nutrition.source`` of an estimated meal; keys ``g.source_glyph``.
SOURCE = "claude"


def __getattr__(name: str) -> object:
    """Resolve the deferred estimator import on first attribute access."""
    if name != "estimate_meal":
        msg = f"module {__name__!r} has no attribute {name!r}"
        raise AttributeError(msg)
    return import_module("diet_guard._claude_estimate").estimate_meal


def start_estimate(text: str) -> queue.Queue[Estimate | None]:
    """Run the estimator on a daemon thread; return its result queue.

    The queue always receives exactly one item: the estimate, or ``None`` for
    any failure (the worker has nowhere to propagate to, so an escaping
    exception would leave the poll waiting for the whole deadline).
    """
    result: queue.Queue[Estimate | None] = queue.Queue(maxsize=1)

    def _worker() -> None:
        """Runs OFF the Tk thread. Touches no widget, by construction."""
        outcome: Estimate | None = None
        with suppress(Exception):
            outcome = sys.modules[__name__].estimate_meal(text, None)
        result.put(outcome)

    threading.Thread(target=_worker, daemon=True).start()
    return result


class ClaudeHooks(NamedTuple):
    """What the flow calls back into the gate."""

    #: The typed description.
    get_desc: Callable[[], str]
    #: The gate's status-line writer.
    set_status: Callable[..., None]
    #: The slot the gate is locking for now, None when nothing is pending.
    slot: Callable[[], int | None]
    #: Log and advance, exactly like a typed meal (``_GateMealFlow._record``).
    record: Callable[[str, Nutrition], None]


class ClaudeFlow:
    """Drives one gate's Claude button through estimate, poll and log."""

    def __init__(self, root: tk.Misc, label: tk.StringVar, hooks: ClaudeHooks) -> None:
        """Bind the flow to a gate.

        Args:
            root: Schedules the poll on the Tk thread.
            label: The button's icon, shared by its copy on every monitor.
            hooks: The gate callbacks the flow drives.
        """
        self._root = root
        self._label = label
        self._hooks = hooks
        self._result: queue.Queue[Estimate | None] | None = None
        self._slot: int | None = None
        self._deadline = 0.0
        self._tick = 0

    def click(self) -> None:
        """Estimate the typed meal; a click while one is running is ignored."""
        if self._result is not None:
            return
        text = self._hooks.get_desc()
        if not text:
            self._hooks.set_status(f"{g.ERROR} {g.FOOD}", error=True)
            return
        self._slot = self._hooks.slot()
        self._deadline = monotonic() + CLAUDE_TIMEOUT_S
        self._tick = 0
        self._label.set(g.CLAUDE_BUSY[0])
        self._result = sys.modules[__name__].start_estimate(text)
        self._root.after(FETCH_POLL_MS, self._poll)

    def _poll(self) -> None:
        """On the Tk thread: spin, time out, or pick up the estimate."""
        result = self._result
        if result is None:
            return
        try:
            estimate = result.get_nowait()
        except queue.Empty:
            if monotonic() >= self._deadline:
                self._finish(failed=True)
                return
            self._tick += 1
            frames = g.CLAUDE_BUSY
            self._label.set(frames[self._tick // _FRAME_TICKS % len(frames)])
            self._root.after(FETCH_POLL_MS, self._poll)
            return
        if estimate is None:
            self._finish(failed=True)
            return
        self._finish(failed=False)
        if self._hooks.slot() != self._slot:
            return  # the user moved on while Claude thought
        nutrition = Nutrition(
            kcal=estimate.kcal,
            protein_g=estimate.protein_g,
            carbs_g=estimate.carbs_g,
            fat_g=estimate.fat_g,
            grams=estimate.grams,
            source=SOURCE,
        )
        self._hooks.record(estimate.desc, nutrition)

    def _finish(self, *, failed: bool) -> None:
        """Free the button before anything else can raise."""
        self._result = None
        self._label.set(g.CLAUDE_FAILED if failed else g.CLAUDE)
