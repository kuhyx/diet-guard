"""Fullscreen "log your meals to unlock" gate window for diet_guard.

This reuses the proven screen-locker *mechanism* -- an ``overrideredirect``
fullscreen window with a global input grab and disabled VT switching -- but
hardens two latent gaps in that original so a grabbed window can never become a
trap:

* **VT switching is restored on every exit path**, not just the clean one:
  ``atexit`` covers a crash/uncaught exception, signal handlers cover
  SIGTERM/SIGINT, and a ``try/finally`` covers normal return.
* **Every callback error is swallowed and surfaced**, via a
  ``report_callback_exception`` override on the Tk root, so no exception can
  propagate out of the grabbed event loop and leave a dead window.

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
"""

from __future__ import annotations

import atexit
import contextlib
import fcntl
import logging
import shutil
import signal
import subprocess
import sys
import time
import tkinter as tk
from typing import TYPE_CHECKING

from python_pkg.diet_guard._budget import (
    BudgetError,
    daily_budget,
    protein_target_g,
)
from python_pkg.diet_guard._constants import GATE_LOCK_FILE
from python_pkg.diet_guard._estimator import Nutrition, scale_nutrition
from python_pkg.diet_guard._foodbank import remember_food, remember_meal
from python_pkg.diet_guard._gate import due_slots
from python_pkg.diet_guard._meal import MealItem, meal_total
from python_pkg.diet_guard._portions import DEFAULT_ITEM_GRAMS, estimate_unit_grams
from python_pkg.diet_guard._resolve import lookup_candidates, suggest_foods
from python_pkg.diet_guard._slots import current_slot, day_slots, slot_label
from python_pkg.diet_guard._state import (
    entry_kcal,
    log_meal,
    now_local,
    today_entries,
    today_total_kcal,
    today_total_macros,
)

if TYPE_CHECKING:
    from collections.abc import Callable
    from types import FrameType, TracebackType
    from typing import TextIO

_logger = logging.getLogger(__name__)

# Palette (mirrors the screen locker's dark, high-contrast lock aesthetic).
_BG = "#1a1a1a"
_FG = "#e0e0e0"
_ACCENT = "#00ff88"
_ERR = "#ff6666"
_FIELD_BG = "#2a2a2a"
_MUTED = "#9a9a9a"
# How long the "unlocking..." confirmation lingers before the window tears down.
_UNLOCK_DELAY_MS = 1200
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
# Number of food-bank / staple / OFF suggestions shown in the picker list.
_SUGGESTION_ROWS = 5
# Grams a label's macros are assumed to describe when the "per" field is blank.
_DEFAULT_PER_GRAMS = 100.0
# Unit-selector choices for how a portion is measured.
_UNIT_GRAMS = "grams"
_UNIT_ITEMS = "items"
# Per-basis label prefixes for the two measuring modes.
_BASIS_PREFIX_GRAMS = "Nutrition as on the label — per"
_BASIS_PREFIX_ITEMS = "Nutrition per 1 item ≈"
# How many recent meals the dashboard lists.
_DASHBOARD_ROWS = 5
# ISO timestamp "YYYY-MM-DDTHH:MM:SS": HH:MM is characters 11..16.
_TIME_SLICE = slice(11, 16)
# Width a meal description is truncated to in the dashboard.
_DASH_DESC_WIDTH = 22
# Fallback name for a multi-item meal when the user leaves the name field blank.
_DEFAULT_MEAL_NAME = "meal"
# -- display readiness (session-start race) ---------------------------------
# The gate's systemd timer fires the instant the user systemd instance starts
# (Persistent=true catch-up of the slot missed while the PC was off), which on a
# fresh login can BEAT the display manager writing ~/.Xauthority and the X server
# becoming reachable.  That race -- not the slot logic -- is what silently
# dropped the session-start launch: _GateRoot() raised TclError ("couldn't
# connect to display") and the oneshot service died.  So before building the
# window we poll the display until it is connectable; on timeout the gate exits
# cleanly and the next timer tick retries, instead of crashing.
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


def _assert_not_under_pytest() -> None:
    """Raise if a real Tk gate is being built inside a pytest run.

    Defence-in-depth: prevents a real fullscreen window from locking the screen
    when a test forgets to mock ``tk.Tk``.  When ``tk`` is mocked the module
    name is no longer ``tkinter``, so genuine mocked tests pass straight through.
    """
    if "pytest" in sys.modules and getattr(tk, "__name__", "") == "tkinter":
        msg = "SAFETY: MealGate built under pytest with real tkinter (tk.Tk unmocked)"
        raise RuntimeError(msg)


def _safe_float(raw: str) -> float | None:
    """Return ``raw`` parsed as a float, or None if it is blank/non-numeric."""
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def _format_preview(nutrition: Nutrition) -> str:
    """Render the one-line "this is what will be logged" preview."""
    portion = f" · {nutrition.grams:g}g" if nutrition.grams else ""
    return (
        f"→ {nutrition.kcal:g} kcal · "
        f"P{nutrition.protein_g:g} C{nutrition.carbs_g:g} F{nutrition.fat_g:g}"
        f"{portion} · {nutrition.source}"
    )


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
        return [current_slot(now_local()) or day_slots()[0]]
    return []


class _GateRoot(tk.Tk):
    """Tk root that routes callback errors to a handler instead of crashing.

    Overriding ``report_callback_exception`` is the idiomatic, blind-except-free
    way to guarantee that no exception raised inside a Tk callback escapes the
    event loop -- essential while a global input grab is held.
    """

    on_callback_error: Callable[[], None] | None = None

    def report_callback_exception(
        self,
        exc: type[BaseException],
        val: BaseException,
        tb: TracebackType | None,
    ) -> None:
        """Log a callback error and notify the handler; never re-raise."""
        _logger.error("gate callback error", exc_info=(exc, val, tb))
        if self.on_callback_error is not None:
            self.on_callback_error()


class MealGate:
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
        self._vt_disabled = False
        self._pending = _pending_slots(demo_mode=demo_mode)
        # Provenance of the values currently in the reference fields ("manual",
        # "food bank", "staple: apple", ...).  Label only -- it never affects the
        # maths, which read the fields directly -- so there is no second copy of
        # the numbers to desync.  Set when a food is picked/looked up; reset to
        # "manual" the moment the user hand-edits a macro.
        self._source = "manual"
        # Suggestions currently listed, paired with their nutrition; the mode
        # says whether picking one should also overwrite the description (bank
        # entries are the user's own names) or only fill macros (OFF products).
        self._suggestions: list[tuple[str, Nutrition]] = []
        self._suggestion_mode = "bank"
        # The natural-basis nutrition of the food last picked or looked up (per
        # 100 g for staples, per logged portion for banked foods).  Kept so a
        # grams<->items toggle can re-express it losslessly in the new basis;
        # set to None the moment the user hand-edits a macro (then there is no
        # clean reference to convert and the fields are cleared instead).
        self._last_reference: Nutrition | None = None
        # Components accumulated for a multi-item meal (salad + chicken + rice)
        # before it is logged as one summed entry; empty for a single food.
        self._meal_items: list[MealItem] = []
        self.root = _GateRoot()
        self.root.on_callback_error = self._handle_callback_error
        self.root.title("Diet Gate" + (" [DEMO]" if demo_mode else ""))
        self._status = tk.StringVar(master=self.root, value="")
        self._slot_header = tk.StringVar(master=self.root, value="")
        self._preview = tk.StringVar(master=self.root, value="")
        self._projection = tk.StringVar(master=self.root, value="")
        self._cal_headline = tk.StringVar(master=self.root, value="")
        self._dashboard = tk.StringVar(master=self.root, value="")
        self._meal_summary = tk.StringVar(master=self.root, value="")
        self._unit = tk.StringVar(master=self.root, value=_UNIT_GRAMS)
        self._desc_text: tk.Text
        self._amount_entry: tk.Entry
        self._per_entry: tk.Entry
        self._basis_prefix: tk.Label
        self._kcal_entry: tk.Entry
        self._protein_entry: tk.Entry
        self._carbs_entry: tk.Entry
        self._fat_entry: tk.Entry
        self._suggestion_box: tk.Listbox
        self._meal_name_entry: tk.Entry
        self._status_label: tk.Label
        self._build()

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
        self.root.configure(bg=_BG, cursor="arrow")
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
            self._desc_text.focus_force()

    # -- UI construction ----------------------------------------------------

    def _build(self) -> None:
        """Lay out the lock UI, seed the first slot prompt, and grab input."""
        self._setup_window()
        frame = tk.Frame(self.root, bg=_BG)
        frame.place(relx=0.5, rely=0.5, anchor="center")

        tk.Label(
            frame,
            text="🍽  Diet Gate",
            font=("Arial", 30, "bold"),
            bg=_BG,
            fg=_ACCENT,
        ).pack(pady=(0, 4))
        tk.Label(
            frame,
            textvariable=self._slot_header,
            font=("Arial", 16, "bold"),
            bg=_BG,
            fg=_FG,
            wraplength=900,
            justify="center",
        ).pack(pady=(0, 10))

        self._build_desc(frame)
        self._suggestion_box = self._build_suggestion_box(frame)
        self._build_amount_row(frame)
        self._build_macro_section(frame)

        for entry in (self._amount_entry, self._per_entry):
            entry.bind("<Return>", self._on_return)
        for entry in self._macro_entries():
            entry.bind("<Return>", self._on_return)
            entry.bind("<KeyRelease>", self._on_macro_edit)

        tk.Label(
            frame,
            textvariable=self._projection,
            font=("Arial", 13, "bold"),
            bg=_BG,
            fg=_FG,
            wraplength=900,
            justify="center",
        ).pack(pady=(2, 2))

        tk.Label(
            frame,
            textvariable=self._preview,
            font=("Arial", 14, "bold"),
            bg=_BG,
            fg=_ACCENT,
            wraplength=900,
            justify="center",
        ).pack(pady=(2, 6))

        self._build_meal_controls(frame)

        tk.Button(
            frame,
            text="Log & Continue",
            font=("Arial", 15, "bold"),
            bg=_ACCENT,
            fg="#003322",
            activebackground="#00cc66",
            cursor="hand2",
            command=self._on_submit,
        ).pack(pady=(4, 6))

        self._status_label = tk.Label(
            frame,
            textvariable=self._status,
            font=("Arial", 12),
            bg=_BG,
            fg=_FG,
            wraplength=900,
            justify="center",
        )
        self._status_label.pack()

        self._build_dashboard(frame)

        if self.demo_mode:
            tk.Button(
                self.root,
                text="✕ Close Demo",
                font=("Arial", 12),
                bg="#ff4444",
                fg="white",
                command=self.close,
                cursor="hand2",
            ).place(x=10, y=10)

        self._relabel_basis()
        self._refresh_slot_header()
        self._refresh_dashboard()
        self._refresh_projection()
        self._grab_input()
        self._desc_text.focus_set()

    def _build_desc(self, parent: tk.Frame) -> None:
        """Build the wrapping, multi-line "what did you eat?" description box.

        A multi-line ``Text`` (not an ``Entry``) so a long restaurant
        description wraps onto a second line and stays fully visible, instead of
        scrolling off the right edge where the end can no longer be read.
        """
        tk.Label(
            parent,
            text="What did you eat?",
            font=("Arial", 12),
            bg=_BG,
            fg=_FG,
        ).pack()
        text = tk.Text(
            parent,
            font=("Arial", 15),
            width=64,
            height=2,
            wrap="word",
            bg=_FIELD_BG,
            fg=_FG,
            insertbackground=_FG,
            highlightthickness=1,
            highlightbackground=_MUTED,
        )
        text.pack(pady=(2, 6))
        text.bind("<KeyRelease>", self._on_desc_keyrelease)
        text.bind("<Return>", self._on_desc_return)
        self._desc_text = text

    def _get_desc(self) -> str:
        """Return the description text, trimmed (a Text always trails a newline)."""
        return self._desc_text.get("1.0", "end-1c").strip()

    def _set_desc(self, value: str) -> None:
        """Replace the description box's contents with ``value``."""
        self._desc_text.delete("1.0", tk.END)
        if value:
            self._desc_text.insert("1.0", value)

    def _on_desc_return(self, _event: tk.Event[tk.Misc]) -> str:
        """Submit on Enter in the description box, suppressing the newline."""
        self._on_submit()
        return "break"

    def _numeric_entry(self, parent: tk.Frame, *, width: int) -> tk.Entry:
        """Return an entry that only accepts a number or a blank string."""
        vcmd = (self.root.register(self._is_numeric_or_blank), "%P")
        return tk.Entry(
            parent,
            font=("Arial", 15),
            width=width,
            bg=_FIELD_BG,
            fg=_FG,
            insertbackground=_FG,
            justify="center",
            validate="key",
            validatecommand=vcmd,
        )

    @staticmethod
    def _is_numeric_or_blank(proposed: str) -> bool:
        """Validate-on-key predicate: allow only a blank field or a number."""
        if proposed == "":
            return True
        try:
            float(proposed)
        except ValueError:
            return False
        return True

    def _build_suggestion_box(self, parent: tk.Frame) -> tk.Listbox:
        """Build the food-bank / staple / OFF picker list and return it."""
        box = tk.Listbox(
            parent,
            font=("Arial", 12),
            width=52,
            height=_SUGGESTION_ROWS,
            bg=_FIELD_BG,
            fg=_FG,
            selectbackground=_ACCENT,
            selectforeground="#003322",
            activestyle="none",
            highlightthickness=0,
        )
        box.bind("<<ListboxSelect>>", self._on_suggestion_select)
        box.pack(pady=(0, 8))
        return box

    def _build_amount_row(self, parent: tk.Frame) -> None:
        """Build the centered "how much did you eat?" amount + unit row."""
        tk.Label(
            parent,
            text="How much did you eat?",
            font=("Arial", 12),
            bg=_BG,
            fg=_FG,
        ).pack()
        row = tk.Frame(parent, bg=_BG)
        row.pack(pady=(2, 6))
        self._amount_entry = self._numeric_entry(row, width=10)
        self._amount_entry.pack(side="left", ipady=3)
        self._amount_entry.bind("<KeyRelease>", self._on_amount_change)
        unit_menu = tk.OptionMenu(
            row,
            self._unit,
            _UNIT_GRAMS,
            _UNIT_ITEMS,
            command=self._on_unit_change,
        )
        unit_menu.configure(
            font=("Arial", 12),
            bg=_FIELD_BG,
            fg=_FG,
            activebackground=_ACCENT,
            highlightthickness=0,
        )
        unit_menu.pack(side="left", padx=(8, 0))

    def _build_macro_section(self, parent: tk.Frame) -> None:
        """Build the per-basis field (grams or item weight) and macro row."""
        basis = tk.Frame(parent, bg=_BG)
        basis.pack()
        self._basis_prefix = tk.Label(
            basis,
            text=_BASIS_PREFIX_GRAMS,
            font=("Arial", 12),
            bg=_BG,
            fg=_FG,
        )
        self._basis_prefix.pack(side="left")
        self._per_entry = self._numeric_entry(basis, width=5)
        self._per_entry.insert(0, f"{_DEFAULT_PER_GRAMS:g}")
        self._per_entry.pack(side="left", padx=4, ipady=2)
        self._per_entry.bind("<KeyRelease>", self._on_amount_change)
        tk.Label(
            basis,
            text="g  (leave calories blank to look it up):",
            font=("Arial", 12),
            bg=_BG,
            fg=_FG,
        ).pack(side="left")

        row = tk.Frame(parent, bg=_BG)
        row.pack(pady=(2, 6))
        self._kcal_entry = self._macro_cell(row, "kcal")
        self._protein_entry = self._macro_cell(row, "P")
        self._carbs_entry = self._macro_cell(row, "C")
        self._fat_entry = self._macro_cell(row, "F")

    def _macro_cell(self, row: tk.Frame, label: str) -> tk.Entry:
        """Pack one small labelled numeric entry into the macro row."""
        cell = tk.Frame(row, bg=_BG)
        cell.pack(side="left", padx=6)
        tk.Label(cell, text=label, font=("Arial", 11), bg=_BG, fg=_FG).pack()
        entry = self._numeric_entry(cell, width=7)
        entry.pack(ipady=3)
        return entry

    def _macro_entries(self) -> tuple[tk.Entry, ...]:
        """Return the four numeric entry widgets in (kcal, P, C, F) order."""
        return (
            self._kcal_entry,
            self._protein_entry,
            self._carbs_entry,
            self._fat_entry,
        )

    def _build_dashboard(self, parent: tk.Frame) -> None:
        """Build the running "how am I doing today" panel.

        The calorie line is large and prominent (the number the user steers by);
        the meal list and macros sit beneath it in a smaller monospace block.
        """
        tk.Label(
            parent,
            textvariable=self._cal_headline,
            font=("Arial", 22, "bold"),
            bg=_BG,
            fg=_ACCENT,
        ).pack(pady=(12, 0))
        tk.Label(
            parent,
            textvariable=self._dashboard,
            font=("Courier", 11),
            bg=_BG,
            fg=_MUTED,
            justify="left",
            anchor="w",
            wraplength=900,
        ).pack(pady=(2, 0))

    def _build_meal_controls(self, parent: tk.Frame) -> None:
        """Build the optional multi-item meal row: name, add button, running sum.

        Logging stays one-tap for a single food; these controls only matter when
        a meal has several separately-macroed parts (a dinner of salad + chicken
        + rice).  "Add item" banks the part onto the meal-in-progress and clears
        the form for the next one; "Log & Continue" then logs the summed meal.
        """
        row = tk.Frame(parent, bg=_BG)
        row.pack(pady=(2, 2))
        tk.Label(
            row,
            text="Meal name (optional):",
            font=("Arial", 11),
            bg=_BG,
            fg=_FG,
        ).pack(side="left")
        self._meal_name_entry = tk.Entry(
            row,
            font=("Arial", 13),
            width=18,
            bg=_FIELD_BG,
            fg=_FG,
            insertbackground=_FG,
        )
        self._meal_name_entry.pack(side="left", padx=(6, 8), ipady=2)
        tk.Button(
            row,
            text="+ Add item",
            font=("Arial", 12, "bold"),
            bg=_FIELD_BG,
            fg=_ACCENT,
            activebackground="#333333",
            cursor="hand2",
            command=self._on_add_item,
        ).pack(side="left")
        tk.Label(
            parent,
            textvariable=self._meal_summary,
            font=("Arial", 11),
            bg=_BG,
            fg=_MUTED,
            wraplength=900,
            justify="center",
        ).pack(pady=(0, 2))

    # -- slot walk ----------------------------------------------------------

    def _refresh_slot_header(self) -> None:
        """Update the header to prompt for the slot now being collected."""
        total = len(self._pending)
        if total == 0:
            self._slot_header.set("All meals logged.")
            return
        slot = self._pending[0]
        position = "" if total == 1 else f"  (1 of {total} remaining)"
        self._slot_header.set(f"Log your {slot_label(slot)} meal{position}")

    def _clear_food_inputs(self) -> None:
        """Empty the food fields, picker, preview, and basis (keeps any meal)."""
        self._set_desc("")
        self._amount_entry.delete(0, tk.END)
        self._unit.set(_UNIT_GRAMS)
        self._relabel_basis()
        self._reset_per_default()
        for entry in self._macro_entries():
            entry.delete(0, tk.END)
        self._suggestion_box.delete(0, tk.END)
        self._suggestions = []
        self._source = "manual"
        self._last_reference = None
        self._preview.set("")
        self._refresh_projection()

    def _clear_inputs(self) -> None:
        """Empty the food fields and discard any in-progress meal (new slot)."""
        self._clear_food_inputs()
        self._meal_items = []
        self._meal_name_entry.delete(0, tk.END)
        self._meal_summary.set("")

    def _reset_per_default(self) -> None:
        """Set the "per" field to the basis default for the current unit."""
        self._per_entry.delete(0, tk.END)
        if self._unit.get() == _UNIT_ITEMS:
            grams = estimate_unit_grams(self._get_desc())
            self._per_entry.insert(
                0, f"{grams if grams is not None else DEFAULT_ITEM_GRAMS:g}"
            )
        else:
            self._per_entry.insert(0, f"{_DEFAULT_PER_GRAMS:g}")

    def _relabel_basis(self) -> None:
        """Point the per-basis label at grams or per-item for the current unit."""
        items = self._unit.get() == _UNIT_ITEMS
        self._basis_prefix.config(
            text=_BASIS_PREFIX_ITEMS if items else _BASIS_PREFIX_GRAMS,
        )

    # -- field helpers ------------------------------------------------------

    def _basis_grams(self) -> float:
        """Return the grams the label macros describe (per 100 g or per item).

        Honours an explicit "per" value when the user has typed one; otherwise
        falls back to one piece's weight in items mode, or 100 g in grams mode.
        """
        typed = _safe_float(self._per_entry.get().strip())
        if typed is not None and typed > 0:
            return typed
        if self._unit.get() == _UNIT_ITEMS:
            grams = estimate_unit_grams(self._get_desc())
            return grams if grams is not None else DEFAULT_ITEM_GRAMS
        return _DEFAULT_PER_GRAMS

    def _eaten_grams(self) -> float | None:
        """Return how many grams were eaten, or None if no amount is entered.

        In grams mode the amount *is* the grams; in items mode it is multiplied
        by one piece's weight (the "per" field), so "5 apples" becomes a weight.
        """
        amount = _safe_float(self._amount_entry.get().strip())
        if amount is None:
            return None
        if self._unit.get() == _UNIT_ITEMS:
            return amount * self._basis_grams()
        return amount

    def _macro_values(self) -> tuple[float | None, ...] | None:
        """Return ``(kcal, P, C, F)`` floats/None, or None if any is non-numeric."""
        values: list[float | None] = []
        for entry in self._macro_entries():
            raw = entry.get().strip()
            parsed = _safe_float(raw)
            if raw and parsed is None:
                return None
            values.append(parsed)
        return tuple(values)

    def _set_entry(self, entry: tk.Entry, value: str) -> None:
        """Replace an entry's contents with ``value``."""
        entry.delete(0, tk.END)
        entry.insert(0, value)

    def _fill_macro_fields(self, nutrition: Nutrition) -> None:
        """Write a nutrition's macros into the kcal/P/C/F fields."""
        pairs = zip(
            self._macro_entries(),
            (
                nutrition.kcal,
                nutrition.protein_g,
                nutrition.carbs_g,
                nutrition.fat_g,
            ),
            strict=True,
        )
        for entry, value in pairs:
            self._set_entry(entry, f"{value:g}")

    # -- the reference -> total model --------------------------------------

    def _reference_nutrition(self) -> Nutrition | None:
        """Return the label values as a Nutrition, or None if calories are blank.

        This is the *reference* (macros for one basis -- per 100 g, or per item),
        not the total: how much was eaten scales it in :meth:`_current_nutrition`.
        """
        values = self._macro_values()
        if values is None or values[0] is None:
            return None
        return Nutrition(
            kcal=values[0],
            protein_g=values[1] or 0.0,
            carbs_g=values[2] or 0.0,
            fat_g=values[3] or 0.0,
            grams=self._basis_grams(),
            source=self._source,
        )

    def _current_nutrition(self) -> Nutrition | None:
        """Return exactly what would be logged now, or None if not yet resolvable.

        The label reference scaled to the amount eaten.  With no amount yet, the
        reference itself stands in (one basis portion), so the preview is never
        empty just because an amount has not been typed.
        """
        reference = self._reference_nutrition()
        if reference is None:
            return None
        eaten = self._eaten_grams()
        return scale_nutrition(reference, eaten) if eaten is not None else reference

    def _refresh_preview(self) -> None:
        """Recompute the preview line and the live calorie projection."""
        nutrition = self._current_nutrition()
        self._preview.set(_format_preview(nutrition) if nutrition is not None else "")
        self._refresh_projection()

    def _refresh_projection(self) -> None:
        """Show consumed / budget / remaining, and what is left after this item.

        This answers, as the calories are typed, the four numbers the user asked
        to see together: how much is already eaten today, the day's goal, how
        much is left now, and how much would be left *after* logging the food
        currently in the form.  With no budget sealed it degrades to the running
        total plus this item's calories, so it is always informative.
        """
        consumed = today_total_kcal()
        nutrition = self._current_nutrition()
        this_kcal = nutrition.kcal if nutrition is not None else 0.0
        try:
            budget = daily_budget()
        except (BudgetError, OSError):
            tail = f" · this item {this_kcal:g} kcal" if this_kcal else ""
            self._projection.set(f"Consumed {consumed:g} kcal today{tail}")
            return
        left = round(budget - consumed, 1)
        base = f"Consumed {consumed:g} / {budget:g} kcal · {left:g} left"
        if this_kcal:
            after = round(budget - consumed - this_kcal, 1)
            self._projection.set(f"{base}   →   after this item: {after:g} left")
        else:
            self._projection.set(base)

    # -- autocomplete / lookup ---------------------------------------------

    def _on_desc_keyrelease(self, _event: tk.Event[tk.Misc]) -> None:
        """Refresh suggestions; in items mode, show the piece's weight."""
        query = self._get_desc()
        self._populate_suggestions(query)
        # In items mode, surface a recognised piece's weight as it is typed, so
        # "apple" visibly becomes "≈ 182 g" rather than a hidden assumption.
        if self._unit.get() == _UNIT_ITEMS:
            grams = estimate_unit_grams(query)
            if grams is not None:
                self._set_entry(self._per_entry, f"{grams:g}")
        self._refresh_preview()

    def _populate_suggestions(self, query: str) -> None:
        """Fill the picker with banked foods and matching staples for ``query``."""
        self._suggestion_mode = "bank"
        self._suggestions = suggest_foods(query, limit=_SUGGESTION_ROWS)
        self._suggestion_box.delete(0, tk.END)
        for name, nutrition in self._suggestions:
            self._suggestion_box.insert(tk.END, f"{name}  ({nutrition.kcal:g} kcal)")

    def _show_candidates(self, candidates: list[tuple[str, Nutrition]]) -> None:
        """Fill the picker with looked-up alternatives to choose from."""
        self._suggestion_mode = "candidates"
        self._suggestions = candidates
        self._suggestion_box.delete(0, tk.END)
        for label, nutrition in candidates:
            self._suggestion_box.insert(
                tk.END,
                f"{label}  ({nutrition.kcal:g} kcal · {nutrition.grams:g}g)",
            )

    def _on_suggestion_select(self, _event: tk.Event[tk.Misc]) -> None:
        """Fill the form from the picked suggestion."""
        selection = self._suggestion_box.curselection()
        if not selection:
            return
        index = selection[0]
        if index >= len(self._suggestions):
            return
        name, nutrition = self._suggestions[index]
        # Banked/staple entries carry a name, so adopt it; OFF products only
        # supply macros and must not overwrite what the user typed.
        if self._suggestion_mode == "bank":
            self._apply_reference(nutrition, name=name)
        else:
            self._apply_reference(nutrition)

    def _apply_reference(
        self, nutrition: Nutrition, *, name: str | None = None
    ) -> None:
        """Adopt ``nutrition`` as the reference and mirror it into the fields.

        In grams mode the food's own weight is the "per" basis and its macros
        fill the fields directly.  In items mode the per-100 g reference is
        converted to a single piece (its weight shown in "per"), so the macro
        fields read *per item*.  The amount eaten does the scaling either way.
        """
        self._source = nutrition.source
        self._last_reference = nutrition
        if name is not None:
            self._set_desc(name)
        if self._unit.get() == _UNIT_ITEMS:
            grams = estimate_unit_grams(self._get_desc())
            unit = grams if grams is not None else DEFAULT_ITEM_GRAMS
            self._set_entry(self._per_entry, f"{unit:g}")
            self._fill_macro_fields(scale_nutrition(nutrition, unit))
        else:
            basis = nutrition.grams or _DEFAULT_PER_GRAMS
            self._set_entry(self._per_entry, f"{basis:g}")
            self._fill_macro_fields(nutrition)
            # Default the eaten amount to one reference portion so a pick is
            # immediately loggable (grams mode only -- items need a count).
            if not self._amount_entry.get().strip() and nutrition.grams:
                self._set_entry(self._amount_entry, f"{nutrition.grams:g}")
        self._refresh_preview()

    # -- live recompute -----------------------------------------------------

    def _on_amount_change(self, _event: tk.Event[tk.Misc]) -> None:
        """Recompute the preview when the amount or basis changes.

        Crucially this does *not* rewrite the macro fields: those hold the label
        reference, and only the previewed/logged total reflects the new amount.
        """
        self._refresh_preview()

    def _on_unit_change(self, _value: str) -> None:
        """Switch grams<->items, re-expressing the picked food in the new basis.

        The macro fields mean different things in each mode (per 100 g / per
        portion vs per item).  When a food was picked or looked up, its stored
        reference is re-applied so toggling converts the values back and forth
        losslessly.  A hand-typed (manual) entry has no clean reference to
        convert, so its fields are cleared to be re-entered in the new basis
        rather than silently reinterpreted.
        """
        self._relabel_basis()
        self._amount_entry.delete(0, tk.END)
        if self._last_reference is not None:
            self._apply_reference(self._last_reference)
            return
        for entry in self._macro_entries():
            entry.delete(0, tk.END)
        self._reset_per_default()
        self._source = "manual"
        self._refresh_preview()

    def _on_macro_edit(self, _event: tk.Event[tk.Misc]) -> None:
        """A hand-edited macro becomes the manual reference from here on.

        Editing a macro by hand invalidates the picked food's stored reference:
        the fields no longer match it, so a later unit toggle must not snap them
        back to it.
        """
        self._source = "manual"
        self._last_reference = None
        self._refresh_preview()

    # -- behaviour ----------------------------------------------------------

    def _set_status(self, text: str, *, error: bool = False) -> None:
        """Update the status line, red for errors."""
        self._status.set(text)
        self._status_label.config(fg=_ERR if error else _FG)

    def _on_return(self, _event: tk.Event[tk.Misc]) -> None:
        """Handle the Enter key in any entry field."""
        self._on_submit()

    def _on_submit(self) -> None:
        """Validate, then look up, or log -- as a single food or a summed meal.

        With a meal in progress, an empty form finalizes the accumulated items,
        and a completed form adds itself as the meal's last item before logging.
        With no meal in progress this is the original single-food path.
        """
        description = self._get_desc()
        if not description:
            if self._meal_items:
                self._log_meal()
                return
            self._set_status("Type what you ate first.", error=True)
            self._desc_text.focus_set()
            return

        values = self._macro_values()
        if values is None:
            self._set_status("Macros must be numbers.", error=True)
            self._kcal_entry.focus_set()
            return

        if values[0] is None:
            self._begin_lookup(description)
            return
        nutrition = self._current_nutrition()
        if nutrition is None:
            self._set_status("Enter the calories, then submit.", error=True)
            self._kcal_entry.focus_set()
            return
        if self._meal_items:
            self._meal_items.append(MealItem(description, nutrition))
            self._log_meal()
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
            self._kcal_entry.focus_set()
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

    def _meal_name(self) -> str:
        """Return the trimmed meal name the user typed (empty if none)."""
        return self._meal_name_entry.get().strip()

    def _refresh_meal_summary(self) -> None:
        """Update the running "meal so far" line from the accumulated items."""
        if not self._meal_items:
            self._meal_summary.set("")
            return
        total = meal_total(self._meal_items)
        names = ", ".join(item.name for item in self._meal_items)
        self._meal_summary.set(
            f"Meal so far ({len(self._meal_items)}): {names}  →  "
            f"{total.kcal:g} kcal · P{total.protein_g:g} "
            f"C{total.carbs_g:g} F{total.fat_g:g}",
        )

    def _on_add_item(self) -> None:
        """Add the current form as one component of a multi-part meal.

        Requires a name and resolved calories (a blank calorie field triggers a
        lookup first, exactly like submitting).  On success the item is appended
        to the meal-in-progress, the running total updates, and the food fields
        clear for the next item while the meal name is kept.
        """
        description = self._get_desc()
        if not description:
            self._set_status("Type the item first, then add it.", error=True)
            self._desc_text.focus_set()
            return
        values = self._macro_values()
        if values is None:
            self._set_status("Macros must be numbers.", error=True)
            self._kcal_entry.focus_set()
            return
        if values[0] is None:
            self._begin_lookup(description)
            return
        nutrition = self._current_nutrition()
        if nutrition is None:
            self._set_status("Enter the calories, then add the item.", error=True)
            self._kcal_entry.focus_set()
            return
        self._meal_items.append(MealItem(description, nutrition))
        self._refresh_meal_summary()
        self._clear_food_inputs()
        self._set_status(f"Added {description}. Add another, or Log & Continue.")
        self._desc_text.focus_set()

    def _slot_for_log(self) -> int | None:
        """Return the slot to tag a log with -- None in demo (satisfies no slot).

        A synthetic demo slot must never satisfy a real checkpoint, so demo logs
        are slot-less: they still bank the food and update the dashboard, but do
        not silently stop the production gate from firing.
        """
        return None if self.demo_mode else self._pending[0]

    def _log_meal(self) -> None:
        """Log the accumulated multi-item meal for the current slot and advance.

        Each component and the summed composite are banked (see
        :func:`python_pkg.diet_guard._foodbank.remember_meal`), and the slot is
        satisfied by the summed total under the meal's name.
        """
        name = self._meal_name() or _DEFAULT_MEAL_NAME
        count = len(self._meal_items)
        total = remember_meal(name, list(self._meal_items))
        log_meal(name, total, self._slot_for_log())
        self._meal_items = []
        self._finish_slot(f"{name}: {total.kcal:g} kcal ({count} items)")

    def _finish_slot(self, summary: str) -> None:
        """Advance past the current slot after something was logged for it.

        Args:
            summary: A short description of what was logged (calories/source, or
                the meal name and item count), shown in the confirmation line.
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
        self._desc_text.focus_set()

    def _unlock(self, logged: str) -> None:
        """Confirm the final log and tear the window down.

        Teardown is scheduled *before* the budget is looked up, so a broken
        budget seal (which raises) can never re-trap the user at unlock time.
        """
        self._set_status(f"{logged} — all meals logged, unlocking…")
        self.root.after(_UNLOCK_DELAY_MS, self.close)

    # -- dashboard ----------------------------------------------------------

    def _refresh_dashboard(self) -> None:
        """Recompute the prominent calorie headline and the detail panel."""
        self._cal_headline.set(self._cal_headline_text())
        self._dashboard.set(self._dashboard_text())

    def _cal_headline_text(self) -> str:
        """Return the big calories-today line: consumed, target, and remaining."""
        consumed = today_total_kcal()
        try:
            budget = daily_budget()
        except (BudgetError, OSError):
            return f"{consumed:g} kcal today"
        return (
            f"{consumed:g} / {budget:g} kcal   ·   {round(budget - consumed, 1):g} left"
        )

    def _dashboard_text(self) -> str:
        """Build the detail panel: recent meals, then macros and protein."""
        lines = ["── Today ───────────────────────────────"]
        entries = today_entries()
        if entries:
            for entry in entries[-_DASHBOARD_ROWS:]:
                clock = str(entry.get("time", ""))[_TIME_SLICE]
                desc = str(entry.get("desc", "?"))[:_DASH_DESC_WIDTH]
                lines.append(
                    f"  {clock:>5}  {desc:<{_DASH_DESC_WIDTH}}  "
                    f"{entry_kcal(entry):>5.0f} kcal",
                )
        else:
            lines.append("  (nothing logged yet today)")
        protein, carbs, fat = today_total_macros()
        lines.append(f"  macros so far:  P{protein:g}  C{carbs:g}  F{fat:g}  g")
        target = protein_target_g()
        if target is not None:
            left = round(target - protein, 1)
            lines.append(f"  protein {protein:g} / {target:g} g  ({left:g} g left)")
        return "\n".join(lines)

    def _handle_callback_error(self) -> None:
        """Surface an unexpected callback error without dropping the grab."""
        self._set_status(
            "Something went wrong. Enter the calories, then submit again.",
            error=True,
        )
        with contextlib.suppress(tk.TclError):
            self._kcal_entry.focus_set()

    # -- lifecycle ----------------------------------------------------------

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
