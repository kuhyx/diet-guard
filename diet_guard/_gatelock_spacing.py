"""Shared spacing scale for the diet_guard gate (tokens.md's 4px scale).

Split out so :mod:`._gatelock_ui` and :mod:`._gatelock_calendar` pick
``pady``/``padx``/``ipady`` values from one deliberate scale instead of
each row inventing its own gap -- see ``DESIGN_AUDIT_TODO.md``. Values are
the px steps from ``~/utils/unified-design-system/tokens.md``'s spacing
scale, used directly as Tk pixel counts.
"""

from __future__ import annotations

XS = 4
SM = 8
MD = 16
LG = 24
XXL = 48
