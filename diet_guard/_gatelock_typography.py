"""Shared type scale for the diet_guard gate (tokens.md's typography scale).

Split out so :mod:`._gatelock_ui`, :mod:`._gatelock_calendar`, and
:mod:`._gatelock_buttons` read the same sizes instead of each picking its
own value per label -- see ``DESIGN_AUDIT_TODO.md``.

**These are Tk font sizes, and Tk encodes the unit in the sign: positive
means points, negative means pixels.** The design-system scale in
``~/utils/unified-design-system/tokens.md`` is in *pixels*, so every constant
here is negative.

This module previously carried the positive values with a comment asserting
that "Tk has no separate px/pt distinction". That premise was wrong, and the
consequence was not cosmetic: at ~100 DPI a positive 16 renders with a 26px
linespace where a negative 16 gives 20px, so every string in the gate was
~30% oversized. That alone pushed the Log Meal tab to 866px of required
height inside a 739px pane on a 1366x768 screen -- clipping the title and the
dashboard symmetrically, with no scrollbar to recover them. Keep the signs
negative; ``tests/test_gatelock_typography.py`` enforces it, and
``tests/measure_gate_layout.py`` enforces the height that depends on it.

``gatelock.LockConfig`` grew the same scale (plus ``LockConfig.font()``, which
applies the sign for you). Once the gatelock pin here moves past v0.2.1, this
module should become a thin re-export of that shared scale rather than a
second copy.
"""

from __future__ import annotations

# Pixel sizes from tokens.md, negated for Tk. Keep in sync with
# gatelock.LockConfig.type_* until this module can defer to it.
DISPLAY = -32
TITLE = -24
SUBTITLE = -20
BODY = -16
LABEL = -14
CAPTION = -12
