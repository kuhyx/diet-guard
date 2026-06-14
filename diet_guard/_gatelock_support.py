"""Session-start display-readiness probing for the diet_guard gate.

Standalone infrastructure split out of :mod:`._gatelock` to keep that module
focused on the gate window itself.  The gate's systemd timer fires the instant
the user systemd instance starts (``Persistent=true`` catch-up of the slot
missed while the PC was off), which on a fresh login can BEAT the display
manager writing ``~/.Xauthority`` and the X server becoming reachable.  That
race -- not the slot logic -- silently dropped the session-start launch: the Tk
root raised ``TclError`` ("couldn't connect to display") and the oneshot
service died.  So before building the window the launcher polls here until the
display is connectable; on timeout the gate exits cleanly and the next timer
tick retries, instead of crashing.
"""

from __future__ import annotations

import logging
import time
import tkinter as tk
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable

_logger = logging.getLogger(__name__)

_DISPLAY_WAIT_TIMEOUT_S = 60.0
_DISPLAY_POLL_INTERVAL_S = 1.0


def _display_is_ready() -> bool:
    """Return True if a Tk root can connect to the X display right now.

    Builds and immediately destroys a throwaway, unmapped root -- the cheapest
    way to ask "is DISPLAY reachable and authorized?" without opening a visible
    window.  A missing display or a not-yet-written X auth cookie raises
    ``tk.TclError``, which is reported here as not-ready.
    """
    try:
        probe = tk.Tk()
    except tk.TclError:
        return False
    probe.destroy()
    return True


def wait_for_display(
    *,
    timeout_s: float = _DISPLAY_WAIT_TIMEOUT_S,
    interval_s: float = _DISPLAY_POLL_INTERVAL_S,
    sleep: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
) -> bool:
    """Block until the X display is connectable, or ``timeout_s`` elapses.

    Absorbs the session-start race in which the gate's timer fires before the
    display manager has finished writing the X auth cookie (see the module
    note).  ``sleep`` and ``monotonic`` are injectable so the wait is tested
    without real time passing.

    Args:
        timeout_s: Total seconds to keep retrying before giving up.
        interval_s: Seconds to wait between connection probes.
        sleep: Sleep function (injected in tests).
        monotonic: Monotonic clock (injected in tests).

    Returns:
        True as soon as a probe connects; False if the deadline passes with the
        display still unreachable (the caller should defer to the next tick).
    """
    deadline = monotonic() + timeout_s
    while True:
        if _display_is_ready():
            return True
        if monotonic() >= deadline:
            _logger.warning(
                "X display unreachable after %.0fs (session still settling?); "
                "deferring the gate to the next timer tick",
                timeout_s,
            )
            return False
        sleep(interval_s)
