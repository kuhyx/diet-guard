"""The Body document's body-fat log: one percentage per date, like weight.

Split out of :mod:`diet_guard._body_store` for the 250-line cap. The newest
live entry switches the calorie table's base BMR to Katch-McArdle
(``_body_calc.table_bmr``); older ones draw the body-fat graph.

KEEP IN SYNC WITH ``app/lib/services/body_service.dart``.
"""

from __future__ import annotations

from diet_guard._body_store import as_number, is_day, now_stamp, read_body, write_body

__all__ = [
    "MAX_BODY_FAT",
    "MIN_BODY_FAT",
    "body_fats",
    "newest_body_fat",
    "set_body_fat",
]

# Outside this range (%) a reading is a typo, not a measurement.
MIN_BODY_FAT = 3.0
MAX_BODY_FAT = 70.0


def body_fats() -> dict[str, float]:
    """``YYYY-MM-DD`` -> body fat % for every live day, oldest first."""
    log = read_body()["bodyfat"]
    live = {
        day: as_number(cell.get("pct")) if isinstance(cell, dict) else None
        for day, cell in log.items()
    }
    return {
        day: pct for day, pct in sorted(live.items()) if pct is not None and is_day(day)
    }


def newest_body_fat() -> float | None:
    """The latest-dated live reading, or None when none is logged."""
    live = body_fats()
    return live[max(live)] if live else None


def set_body_fat(day: str, pct: float | None) -> None:
    """Record (or, with ``pct=None``, delete) ``day``'s body fat, stamped now."""
    doc = read_body()
    value = None if pct is None else round(float(pct), 1)
    doc["bodyfat"][day] = {"pct": value, "t": now_stamp()}
    write_body(doc)
