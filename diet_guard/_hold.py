"""Hold integration: no lock and no owed slot while a declared hold is active.

A *hold* (the ``holds`` package, contract holds-v0.1.0) is a ratcheted,
time-boxed window in which the PC must stay fully usable (a proctored test).
This module is the single seam between the gate and that package.

Fail mode, chosen out loud: **closed**.  If ``holds`` is missing, corrupt or
raises, :func:`hold_covers` returns False and the gate behaves exactly as it
does without holds -- a broken holds package can never switch the gate off.
"""

from __future__ import annotations

from importlib import import_module
import logging
from typing import TYPE_CHECKING

from diet_guard._state import now_local

if TYPE_CHECKING:
    from collections.abc import Callable
    from datetime import datetime
    import tkinter as tk

__all__ = ["HOLD_GATE", "HOLD_POLL_MS", "HoldWatch", "hold_covers", "watch_hold"]

HOLD_GATE = "diet"
# An open lock re-reads the (local, tiny) holds file this often, so a hold that
# starts under a live lock lifts it in <= 30 s -- inside the 60 s contract.
HOLD_POLL_MS = 30_000

_LOG = logging.getLogger(__name__)


def hold_covers(at: datetime) -> bool:
    """Return True if a hold covers the diet gate at local time ``at``.

    Args:
        at: The instant to test (may be a future slot time); aware values are
            reduced to naive local wall-clock, which is what ``holds`` stores.

    Returns:
        True inside a hold; False outside one *and* whenever ``holds`` cannot
        be imported or raises (fail closed: normal rules apply).
    """
    try:
        holds = import_module("holds")
        return bool(holds.covers(HOLD_GATE, at.replace(tzinfo=None)))
    except ImportError, AttributeError, OSError, TypeError, ValueError:
        _LOG.exception("holds unavailable; treating the gate as not on hold")
        return False


class HoldWatch:
    """Close the open lock window as soon as a hold becomes active."""

    def __init__(self, root: tk.Misc, close: Callable[[], None]) -> None:
        """Bind the Tk root (for ``after``) and the window's close callback."""
        self._root = root
        self._close = close

    def start(self) -> None:
        """Schedule the first check."""
        self._root.after(HOLD_POLL_MS, self.tick)

    def tick(self) -> None:
        """Lift the lock if a hold is active now, else check again later."""
        if hold_covers(now_local()):
            self._close()
            return
        self._root.after(HOLD_POLL_MS, self.tick)


def watch_hold(root: tk.Misc, close: Callable[[], None]) -> None:
    """Start a :class:`HoldWatch` on ``root`` that calls ``close`` on a hold."""
    HoldWatch(root, close).start()
