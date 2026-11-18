"""Error and slow-wait reporting for the diet gate (utils DOCS-app-errors.md).

``install`` runs once from the CLI entry point: uncaught, thread and Tk
callback errors, and a Tk loop frozen over 1 s, go to the app-errors spool,
from which the PC's ingest files a board ticket. Only the CLI installs it, so
tests that build a gate window never touch the real spool. The Flutter app
reports separately, as ``diet-guard``.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from gatelock import error_report
from gatelock.error_report import watch_stalls

if TYPE_CHECKING:
    import tkinter as tk

APP = "diet-guard-gate"
REPO = "kuhyx/diet-guard"


@dataclass
class _Slot:
    """Holds the process's reporter once installed."""

    reporter: error_report.Reporter | None = None


#: The installed reporter (``SLOT.reporter``); None until ``install``.
SLOT = _Slot()


def install() -> error_report.Reporter:
    """Hook this process's errors once; return the reporter."""
    SLOT.reporter = error_report.install(APP, REPO)
    return SLOT.reporter


def watch(root: tk.Misc) -> None:
    """Report ``root``'s freezes over 1 s, once ``install`` has run."""
    if SLOT.reporter is not None:
        watch_stalls(root, SLOT.reporter)
