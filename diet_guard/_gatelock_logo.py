"""The kuhy logo in a corner of each gate surface (shared ``kuhy_credit``).

Uses the Tk widget from kuhy_credit (kuhy-credit-v0.3.0). A click opens the
credit panel; the site opens only on a further click, so the lock cannot be
escaped by accident. This module imports tkinter and builds widgets, so it
belongs in ``_GATE_TK_MODULES`` (see ``_gatelock_layout``).
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from kuhy_credit.tk import KuhyCredit

if TYPE_CHECKING:
    import tkinter as tk

__all__ = ["place_logo"]

_MARGIN = 16


def place_logo(parent: tk.Misc) -> KuhyCredit:
    """Overlay the logo on ``parent``'s bottom-right corner."""
    credit = KuhyCredit(parent, theme="dark")
    credit.place(relx=1, rely=1, x=-_MARGIN, y=-_MARGIN, anchor="se")
    return credit
