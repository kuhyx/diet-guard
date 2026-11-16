"""The open gate window notices a meal that was logged somewhere else.

Until 2026-11-16 the window's only passive watcher was ``watch_hold``; a meal
the phone (or any other process) wrote to the local log while the window was up
changed nothing until the user pressed Fetch. This hands the shared
``gatelock.watch_credit`` three things diet_guard already has:

* the file to watch -- the food log ``log_meal`` and every sync merge write;
* "is it done?" -- :func:`diet_guard._gate.due_slots`, never a second copy of
  the rule: done when none of the slots this window still owes is due any more;
* the exit -- the window's own reconcile (``_reconcile_after_fetch``), the same
  path the Fetch button takes, so the status line and unlock delay are identical.

The credit was already written by whoever logged it. Closing writes nothing.
Failure mode: closed -- a log that cannot be read keeps the lock up.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from gatelock import watch_credit

from diet_guard import _state
from diet_guard._gate import due_slots

if TYPE_CHECKING:
    from collections.abc import Callable
    from tkinter import Misc

__all__ = ["arm_credit_watch"]


def arm_credit_watch(
    root: Misc,
    pending: Callable[[], list[int]],
    on_credit: Callable[[], None],
) -> None:
    """Close the window once every slot it still owes is covered by the log.

    Args:
        root: The gate's Tk root.
        pending: Returns the slots the window still owes. A callable, because
            the window rebuilds that list as slots are satisfied.
        on_credit: The window's reconcile/close path.
    """

    def _all_covered() -> bool:
        owed = set(pending())
        return bool(owed) and owed.isdisjoint(due_slots())

    watch_credit(root, (_state.food_log_path(),), _all_covered, on_credit)
