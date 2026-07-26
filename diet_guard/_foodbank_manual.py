"""Hand-curated food bank entries: foods added without ever eating them.

The main food bank (:mod:`diet_guard._foodbank`) is *derived* -- every record
is replayed from the synced food log, so both devices compute the same bank
from the same input and it needs no sync of its own.  This module holds the
part that is **not** derivable: entries the user added by hand in the phone
app's food-bank screen, which never appear in any log.

Those were previously phone-only, which made them the last piece of
device-local state in the app.  They now sync like everything else -- one
``crdt_sync`` record per normalized name, last-writer-wins by edit time -- so
a food added on the phone autocompletes in the PC gate and vice versa.

Kept in a separate file from the derived bank on purpose: the derived bank is
rewritten wholesale on every log write (:func:`diet_guard._foodbank.
rebuild_food_bank`), so storing curated entries there would lose them on the
next meal.
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
import logging

from diet_guard._constants import MANUAL_BANK_FILE

_logger = logging.getLogger(__name__)

# On-disk shape: {normalized_name: {..bank record fields.., "t": <local ISO>}}.
# ``t`` is the edit timestamp the sync merge compares; it is not part of the
# record's nutritional meaning.
ManualRecord = dict[str, object]

_EPOCH_ISO = "1970-01-01T00:00:00+00:00"


def read_manual_bank() -> dict[str, ManualRecord]:
    """Return the hand-curated bank, or an empty dict on any error.

    Never raises: a missing or unreadable file simply means "no curated
    entries", which every caller already handles.
    """
    if not MANUAL_BANK_FILE.exists():
        return {}
    try:
        with MANUAL_BANK_FILE.open() as handle:
            bank = json.load(handle)
    except (OSError, json.JSONDecodeError):
        _logger.warning("Manual food bank %s is unreadable", MANUAL_BANK_FILE)
        return {}
    if not isinstance(bank, dict):
        return {}
    return {str(key): value for key, value in bank.items() if isinstance(value, dict)}


def write_manual_bank(bank: dict[str, ManualRecord]) -> None:
    """Persist ``bank`` verbatim, overwriting the file."""
    MANUAL_BANK_FILE.parent.mkdir(parents=True, exist_ok=True)
    with MANUAL_BANK_FILE.open("w") as handle:
        json.dump(bank, handle)


def record_edit_time(record: ManualRecord) -> str:
    """Return ``record``'s edit timestamp, or the epoch when it has none."""
    stamp = record.get("t")
    return stamp if isinstance(stamp, str) else _EPOCH_ISO


def add_manual_entry(name: str, record: ManualRecord) -> None:
    """Add or replace the curated entry for ``name``, stamping the edit time.

    Args:
        name: The food's display name; its normalized form is the key.
        record: The bank fields to store (``t`` is set here, not by callers).
    """
    bank = read_manual_bank()
    stamped = dict(record)
    stamped["t"] = (
        datetime.now(tz=timezone.utc)
        .astimezone()
        .isoformat(
            timespec="seconds",
        )
    )
    bank[name.strip().casefold()] = stamped
    write_manual_bank(bank)
