"""How a log entry records its meal slot on disk and on the sync wire.

Slots are minutes of day (see :mod:`diet_guard._slots`), but every entry ever
written before that change carries an hour in ``"slot"``, and a peer running an
older build reads only that field.  So the wire rule is additive:

* **Writers** always write ``"slot" = minute // 60`` and add
  ``"slot_min" = minute`` *only* when ``minute % 60 != 0``.  A whole-hour slot
  therefore encodes byte-identically to the pre-minute format -- no re-signing
  storm, no diff on every existing entry -- and an older peer reading an
  off-hour entry sees the hour it starts in.  :func:`slot_fields` is that rule.
* **Readers** prefer an int ``"slot_min"``, fall back to ``"slot" * 60``, and
  otherwise report no slot.  :func:`entry_slot_minute` is that rule.

``bool`` is rejected wherever an int is expected: Python's ``bool`` subclasses
``int`` but Dart's does not, and a value one device accepts while the other
ignores is the cross-device split brain the shared fixture exists to catch.

KEEP IN SYNC WITH ``app/lib/models/slot.dart`` (``slotFields``,
``entrySlotMinute``); ``tests/fixtures/meal_schedule_vectors.json`` gates both.
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

from diet_guard._meal_schedule import MINUTES_PER_DAY, is_wire_int

if TYPE_CHECKING:
    from collections.abc import Mapping

# ASCII digits only: ``\d`` would also accept Arabic-Indic and other Unicode
# digits, which ``int()`` happily parses.
_HHMM = re.compile(r"([0-9]{1,2})(?::([0-9]{2}))?")
_HOURS_PER_DAY = 24
_MINUTES_PER_HOUR = 60


def slot_fields(minute: int) -> dict[str, int]:
    """Return the entry fields that record ``minute`` as its slot.

    Args:
        minute: The slot's minute of day, ``0..1439``.

    Returns:
        ``{"slot": hour}``, plus ``"slot_min"`` when ``minute`` is off the hour.

    Raises:
        ValueError: ``minute`` is outside the day -- a writer bug, refused
            rather than encoded, since ``//`` on a negative value would floor
            here and truncate in Dart.
    """
    if not 0 <= minute < MINUTES_PER_DAY:
        msg = f"slot minute {minute} is outside 0..{MINUTES_PER_DAY - 1}"
        raise ValueError(msg)
    fields = {"slot": minute // 60}
    if minute % 60:
        fields["slot_min"] = minute
    return fields


def entry_slot_minute(entry: Mapping[str, object]) -> int | None:
    """Return the slot minute an entry records, or None when it has none.

    Args:
        entry: One decoded log entry.

    Returns:
        ``entry["slot_min"]`` if it is an int, else ``entry["slot"] * 60`` if
        that is an int, else None.  Values are not range-checked: an entry is
        reported as written, and :func:`diet_guard._slots.nearest_slot` maps
        anything onto a real slot.
    """
    slot_min = entry.get("slot_min")
    if is_wire_int(slot_min):
        return slot_min
    slot = entry.get("slot")
    if is_wire_int(slot):
        return slot * 60
    return None


def parse_hhmm(text: str) -> int:
    """Parse a user-typed clock time into a minute of day.

    Accepts ``H``, ``HH``, ``H:MM`` and ``HH:MM`` with surrounding whitespace,
    e.g. ``"7"`` -> 420, ``"07:15"`` -> 435.

    Args:
        text: The time as typed.

    Returns:
        The minute of day, ``0..1439``.

    Raises:
        ValueError: ``text`` is not in one of those forms, or the hour is not
            0-23 or the minutes not 0-59.
    """
    match = _HHMM.fullmatch(text.strip())
    if match is None:
        msg = f"invalid time {text!r}, expected HH:MM (e.g. 07:15) or HH"
        raise ValueError(msg)
    hour = int(match.group(1))
    minute = int(match.group(2) or 0)
    if hour >= _HOURS_PER_DAY or minute >= _MINUTES_PER_HOUR:
        msg = f"invalid time {text!r}: hour must be 0-23 and minutes 0-59"
        raise ValueError(msg)
    return hour * 60 + minute
