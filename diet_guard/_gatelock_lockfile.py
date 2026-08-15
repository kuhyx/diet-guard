"""Single-instance ``flock`` for the meal gate.

Split out of :mod:`._gatelock` to keep every gate module under the repo's
250-line limit.  Deliberately the *stdlib-only* half of the gate: no ``tkinter``
import, so this module never needs to appear in the test suite's
``_GATE_TK_MODULES`` fake-tk patch set.
"""

from __future__ import annotations

import contextlib
import fcntl
from typing import TYPE_CHECKING

from diet_guard._constants import GATE_LOCK_FILE

if TYPE_CHECKING:
    from typing import TextIO

__all__ = [
    "GATE_LOCK_FILE",
    "acquire_gate_lock",
    "release_gate_lock",
]


def acquire_gate_lock() -> TextIO | None:
    """Acquire the gate's single-instance ``flock``.

    Returns:
        An open file handle that must be kept alive for the gate's lifetime
        (closing it releases the lock), or None if another gate already holds
        it -- in which case the caller must not open a second window.
    """
    GATE_LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    handle = GATE_LOCK_FILE.open("w", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    return handle


def release_gate_lock(handle: TextIO) -> None:
    """Release the single-instance lock and close its handle."""
    with contextlib.suppress(OSError):
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    handle.close()
