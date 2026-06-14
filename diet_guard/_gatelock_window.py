"""Window mechanics and process lifecycle for the MealGate gate.

Split out of :mod:`._gatelock` to keep that module under the repo's 500-line
limit.  ``_GateWindow`` extends
:class:`~python_pkg.diet_guard._gatelock_core._GateCore` with the
screen-locker-style window setup (fullscreen, VT-switch disable, global input
grab with retry) and the signal/atexit lifecycle that guarantees VT switching
is restored on every exit path.
"""

from __future__ import annotations

import atexit
import contextlib
import logging
import shutil
import signal
import subprocess
import tkinter as tk
from typing import TYPE_CHECKING

from python_pkg.diet_guard._gatelock_core import _GateCore
from python_pkg.diet_guard._gatelock_ui import BG

if TYPE_CHECKING:
    from types import FrameType

_logger = logging.getLogger(__name__)

# Periodic no-op so the grabbed, event-starved loop keeps handing control back
# to Python, letting SIGTERM/SIGINT be serviced promptly.
_KEEPALIVE_MS = 250
# A global input grab fails while another X client already holds one -- most
# often a FULLSCREEN GAME, which takes an exclusive keyboard/pointer grab.  A
# single attempt then falls back to a *local* grab, which on an override-redirect
# window the WM refuses to focus means no keystroke ever reaches the field -- the
# "can't type anything" lock-trap.  So the grab is retried for the window's whole
# life: the gate waits out the game and captures input the instant it is freed.
_GRAB_RETRY_MS = 200
# How often (in attempts) to log that the grab is still blocked, so the journal
# shows the gate is alive and waiting rather than hung.  ~every 5 s at 200 ms.
_GRAB_LOG_EVERY = 25


class _GateWindow(_GateCore):
    """Fullscreen window setup, input grab, and exit-path lifecycle."""

    # -- window mechanics (reused screen-locker pattern) --------------------

    def _setup_window(self) -> None:
        """Configure the lock window.

        Demo mode stays WM-managed so the window manager still grants it
        keyboard focus -- and you can always close it -- making a usable, safe
        sandbox.  Only the real lock uses ``overrideredirect``, where the tiling
        WM refuses focus and input is instead forced in by a global grab.
        """
        screen_w = self.root.winfo_screenwidth()
        screen_h = self.root.winfo_screenheight()
        self.root.geometry(f"{screen_w}x{screen_h}+0+0")
        self.root.attributes(topmost=True)
        self.root.configure(bg=BG, cursor="arrow")
        if self.demo_mode:
            self.root.attributes(fullscreen=True)
        else:
            self.root.overrideredirect(boolean=True)
            self.root.attributes(fullscreen=True)
            self._disable_vt_switching()

    def _disable_vt_switching(self) -> None:
        """Block Ctrl+Alt+Fn TTY switching while the lock is up (best-effort)."""
        setxkbmap = shutil.which("setxkbmap")
        if setxkbmap is None:
            _logger.warning("setxkbmap not found; VT switching stays enabled")
            return
        subprocess.run([setxkbmap, "-option", "srvrkeys:none"], check=False)
        self._vt_disabled = True

    def _restore_vt_switching(self) -> None:
        """Re-enable VT switching; idempotent and safe to call on any exit."""
        if not self._vt_disabled:
            return
        setxkbmap = shutil.which("setxkbmap")
        if setxkbmap is not None:
            subprocess.run([setxkbmap, "-option", ""], check=False)
        self._vt_disabled = False

    def _grab_input(self) -> None:
        """Force input to the window, then focus the first field.

        Demo mode relies on normal WM focus (no grab), keeping the window an
        escapable sandbox.  The real lock forces *all* input here with a global
        grab -- the only mechanism that reaches an overrideredirect window the
        tiling WM will not focus.  The grab is acquired with retries because it
        commonly fails on the first attempt while the window is still mapping.
        """
        self.root.update_idletasks()
        self.root.focus_force()
        if not self.demo_mode:
            self._acquire_global_grab(attempt=1)
        self.root.after(100, self._focus_first_field)

    def _acquire_global_grab(self, *, attempt: int) -> None:
        """Acquire the global input grab, retrying until it succeeds.

        A successful global grab is the only way keystrokes reach the
        override-redirect window the WM will not focus.  When another client
        (typically a fullscreen game) holds the grab, the attempt is rescheduled
        indefinitely rather than conceding to an unusable local grab, so the gate
        waits the other application out and captures input the moment it frees
        the grab.  On success, focus is forced onto the description field so the
        first keystroke lands there.

        Args:
            attempt: 1-based attempt counter, used only to throttle the log.
        """
        try:
            self.root.grab_set_global()
        except tk.TclError:
            if attempt % _GRAB_LOG_EVERY == 0:
                _logger.warning(
                    "global grab still blocked after %d attempts (another app -- "
                    "e.g. a fullscreen game -- holds it); waiting for it to free",
                    attempt,
                )
            self.root.after(
                _GRAB_RETRY_MS,
                lambda: self._acquire_global_grab(attempt=attempt + 1),
            )
            return
        with contextlib.suppress(tk.TclError):
            self.root.focus_force()
            self._focus_first_field()

    def _focus_first_field(self) -> None:
        """Put keyboard focus on the description entry once it is mapped."""
        with contextlib.suppress(tk.TclError):
            self._widgets.desc_text.focus_force()

    # -- lifecycle ------------------------------------------------------------

    def _install_signal_handlers(self) -> None:
        """Ensure VT switching is restored on crash or kill, not just close."""
        atexit.register(self._restore_vt_switching)
        for sig in (signal.SIGTERM, signal.SIGINT):
            with contextlib.suppress(ValueError):
                signal.signal(sig, self._on_signal)

    def _on_signal(self, _signum: int, _frame: FrameType | None) -> None:
        """Restore the keyboard escape, then exit, on SIGTERM/SIGINT."""
        self._restore_vt_switching()
        raise SystemExit(0)

    def _keepalive(self) -> None:
        """Re-arm a periodic no-op so pending signals get serviced promptly."""
        self.root.after(_KEEPALIVE_MS, self._keepalive)

    def close(self) -> None:
        """Restore VT switching and destroy the window (no process exit)."""
        self._restore_vt_switching()
        with contextlib.suppress(tk.TclError):
            self.root.destroy()

    def run(self) -> None:
        """Run the Tk loop, restoring VT switching on every exit path."""
        self._install_signal_handlers()
        self._keepalive()
        try:
            self.root.mainloop()
        finally:
            self._restore_vt_switching()
