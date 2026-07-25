"""Shared type scale for the diet_guard gate (tokens.md's typography scale).

Split out so :mod:`._gatelock_ui`, :mod:`._gatelock_calendar`, and
:mod:`._gatelock_buttons` read the same sizes instead of each picking its
own point value per label -- see ``DESIGN_AUDIT_TODO.md``. Values are the
px sizes from ``~/utils/unified-design-system/tokens.md``'s typography
scale, used directly as Tk point sizes (Tk has no separate px/pt distinction
in this codebase's existing font tuples).
"""

from __future__ import annotations

DISPLAY = 32
TITLE = 24
SUBTITLE = 20
BODY = 16
LABEL = 14
CAPTION = 12
