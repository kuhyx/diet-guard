"""Pure log-merge logic for diet_guard's cross-device sync.

No I/O here -- this module is unit-testable purely on in-memory ``DayLog``
values, like :mod:`diet_guard._slots`.  Mirrored test-for-test by the Dart
port (``app/lib/services/sync_service.dart``), so the merge algorithm
canonically agrees on both sides of the sync.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from diet_guard._state import DayLog

# A dedup key: ("id", <uuid string>) for any entry with one, else
# ("legacy", (time, desc)) for a pre-id entry written before this field
# existed -- two devices that both already had that same legacy entry would
# otherwise end up with two copies of it after a merge.
_Key = tuple[str, object]


def _entry_key(entry: dict[str, object]) -> _Key:
    """Return the dedup key for ``entry``."""
    entry_id = entry.get("id")
    if isinstance(entry_id, str) and entry_id:
        return ("id", entry_id)
    return ("legacy", (entry.get("time"), entry.get("desc")))


def _tombstone_wins(
    candidate: dict[str, object],
    existing: dict[str, object],
) -> bool:
    """Return True if ``candidate`` should replace ``existing`` for one key.

    A tombstone always wins over a non-tombstoned copy of the same entry --
    deletion is sticky, so a stale pre-undo copy pulled from another device
    can never resurrect something the user explicitly removed.  Otherwise,
    keep whichever copy was seen first: two copies of the same id are
    expected to be byte-identical in their macros/desc (the body is never
    mutated after creation, only ``deleted``/``hmac``), so which one survives
    does not change the merged result's content.
    """
    return bool(candidate.get("deleted")) and not existing.get("deleted")


def merge_logs(local: DayLog, remote: DayLog) -> DayLog:
    """Return the union of ``local`` and ``remote``, tombstones winning by id.

    Commutative and idempotent: ``merge_logs(a, b) == merge_logs(b, a)`` and
    ``merge_logs(x, x) == x`` (for an ``x`` with no duplicate keys), so
    pull-order between devices never matters and a repeated sync tick is a
    no-op.  Each entry is re-bucketed under its own ``time``'s date rather
    than the date key it arrived under, so a merge can't silently leave an
    entry filed under the wrong day.

    Args:
        local: This device's current full log (including tombstones).
        remote: Another device's last-pushed full log.

    Returns:
        The merged log, keyed by each entry's own date, each day's entries
        sorted oldest-first (matching the existing on-disk convention).
    """
    by_key: dict[_Key, dict[str, object]] = {}
    for day_log in (local, remote):
        for entries in day_log.values():
            for entry in entries:
                key = _entry_key(entry)
                existing = by_key.get(key)
                if existing is None or _tombstone_wins(entry, existing):
                    by_key[key] = entry

    merged: DayLog = {}
    for entry in by_key.values():
        date_key = str(entry.get("time", ""))[:10]
        merged.setdefault(date_key, []).append(entry)
    for entries in merged.values():
        entries.sort(key=lambda entry: str(entry.get("time", "")))
    return merged
