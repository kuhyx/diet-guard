"""Shared primary/secondary/danger button builder for the diet_guard gate.

Split out of :mod:`._gatelock_ui` to keep every gate module under the repo's
500-line limit. Centralizes what used to be 7 independent ``tk.Button(...)``
calls (across :mod:`._gatelock_ui` and :mod:`._gatelock_calendar`) each
picking their own bg/fg/activebackground -- see ``DESIGN_AUDIT_TODO.md``.
"""

from __future__ import annotations

import tkinter as tk
from typing import TYPE_CHECKING, Literal

from gatelock import LockConfig

from diet_guard._gatelock_typography import BODY, LABEL

if TYPE_CHECKING:
    from collections.abc import Callable

_COLORS = LockConfig()


def _lighten(hex_color: str, amount: float = 0.12) -> str:
    """Blend ``hex_color`` toward white by ``amount``, for a button hover state."""
    red, green, blue = (int(hex_color[i : i + 2], 16) for i in (1, 3, 5))
    return "#" + "".join(
        f"{round(channel + (255 - channel) * amount):02x}"
        for channel in (red, green, blue)
    )


# Fill/text pairs per button role, read from the shared LockConfig palette
# instead of each call site inventing its own hex pair. "primary" is the
# one high-emphasis action per screen (rule 3); "secondary" and "danger"
# stay low-contrast/alarm respectively. All three use `on_fill` (never
# `fg`) for text-on-a-filled-surface, per tokens.md.
_BUTTON_FILLS: dict[str, tuple[str, str]] = {
    "primary": (_COLORS.accent, _COLORS.on_fill),
    "secondary": (_COLORS.field_bg, _COLORS.fg),
    "danger": (_COLORS.danger, _COLORS.on_fill),
}
# The one high-emphasis button per screen reads larger than everything else
# (rule 3: size is another axis of prominence, alongside color) -- every
# other variant shares the same, smaller chrome size (tokens.md's type scale).
_BUTTON_SIZE: dict[str, int] = {
    "primary": BODY,
    "secondary": LABEL,
    "danger": LABEL,
}
# Horizontal = 2x vertical (tokens.md "Buttons"; both on the 4px spacing scale).
_BUTTON_PADY = 12
_BUTTON_PADX = 24


def make_button(
    parent: tk.Misc,
    *,
    text: str,
    variant: Literal["primary", "secondary", "danger"],
    command: Callable[[], None],
    bold: bool = True,
) -> tk.Button:
    """Build a button from the shared primary/secondary/danger palette."""
    fill, text_color = _BUTTON_FILLS[variant]
    size = _BUTTON_SIZE[variant]
    font = (_COLORS.font_family, size, "bold") if bold else (_COLORS.font_family, size)
    return tk.Button(
        parent,
        text=text,
        font=font,
        bg=fill,
        fg=text_color,
        activebackground=_lighten(fill),
        cursor="hand2",
        padx=_BUTTON_PADX,
        pady=_BUTTON_PADY,
        command=command,
    )
