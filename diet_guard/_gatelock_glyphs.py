"""The PC gate's glyph vocabulary: one shape per concept, no words.

kuhy's textgate rule (2026-11-08): nothing the gate paints carries a word.
Every Tk surface draws from this one table so a concept looks the same on the
Log Meal, History and Body tabs. Plain geometric BMP characters only, all in
DejaVu Sans: colour emoji can crash Tk 8.6 and the gate is the one window
that must never fail to draw. ``test_gate_no_words`` is the guard.

The macro shapes match the phone app's ``MacroKind`` (protein circle, carbs
triangle, fat square), so one vocabulary reads the same on both devices.
"""

from __future__ import annotations

from typing import Final

# Status cues: the status line shows one of these instead of a sentence.
OK: Final = "✓"
ERROR: Final = "✗"
BUSY: Final = "⋯"
EMPTY: Final = "∅"
DEMO_ONLY: Final = "⊘"
WARN: Final = "⚠"

# Fields and concepts.
FOOD: Final = "✎"
AMOUNT: Final = "⚖"
PROTEIN: Final = "●"
CARBS: Final = "▲"
FAT: Final = "■"
MACRO_COLORS: Final = {"protein": "#6abf69", "carbs": "#e0a33a", "fat": "#6b9bef"}
BUDGET: Final = "⚑"
CLOCK: Final = "◷"
AVERAGE: Final = "⌀"
BIRTH: Final = "✱"
RESTING: Final = "☾"
IDEAL: Final = "◎"
STEPS: Final = "⇶"
MEASURED: Final = "◉"
TIMES: Final = "\N{MULTIPLICATION SIGN}"
ITEMS: Final = TIMES
GRAMS: Final = "g"

# Actions.
SUBMIT: Final = "✓"
EDIT: Final = "✎"
SAVE: Final = "✓"
DELETE: Final = "⌫"
CLOSE: Final = "✕"
SYNC: Final = "⟳"
DELIVERY: Final = "▣"
FILL_ALL: Final = "⇊"
INFINITE: Final = "∞"
UNLOCKING: Final = "⇥"

# Notebook tabs.
TAB_LOG: Final = "✚"
TAB_HISTORY: Final = "▦"
TAB_BODY: Final = "♙"

# Profile sex, goal direction and goal span.
MALE: Final = "♂"
FEMALE: Final = "♀"
DIRECTION: Final = {"lose": "↓", "maintain": "=", "gain": "↑"}
SPAN: Final = {"day": "◔", "week": "◑", "month": "◕", "year": "●"}

# Summaries: the year's tally, an empty value, and how an average compared
# with its budget (``AverageBand`` values; shape and fill grow with the excess).
YEAR_TOTAL: Final = "Σ"
DASH: Final = "\N{EN DASH}"
NO_VALUE: Final = DASH
BAND: Final = {"under": "✓", "slightly_over": "△", "very_over": "▲"}

# Weekday header: weekdays small, the weekend larger (no day names).
WEEKDAY: Final = "•"
WEEKEND: Final = "●"
WEEKDAY_DOTS: Final = (WEEKDAY,) * 5 + (WEEKEND,) * 2


def source_glyph(source: str) -> str:
    """Where a nutrition came from: food bank, staple, catering, typed, looked up."""
    head = source.split(":", 1)[0].strip()
    return {
        "food bank": "▤",
        "staple": "★",
        "catering": DELIVERY,
        "manual": FOOD,
    }.get(head, "≈")
