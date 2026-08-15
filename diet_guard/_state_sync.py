"""Raw-log access, re-signing, and undo for the signed food log.

Split out of :mod:`._state` to keep both files under the repo's 250-line
limit.  These are the *write*-side and sync-side helpers: unverified reads
(:func:`read_raw_log`), the merge write-back (:func:`write_raw_log`), the
per-entry re-sign the sync tick applies to every persisted entry
(:func:`resign_entry`), and the tombstoning undo.

They reach the file only through :mod:`._state`'s private ``_read_raw_log`` /
``_write_log``, which is where ``FOOD_LOG_FILE`` stays -- ``tests/conftest.py``
redirects the log by patching ``diet_guard._state.FOOD_LOG_FILE``, so a copy
of that constant here would be a patch the tests no longer reach. The names
are re-exported from :mod:`._state` for the existing call sites.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from gatelock.log_integrity import compute_entry_hmac

from diet_guard._state import _read_raw_log, _today, _write_log

if TYPE_CHECKING:
    from diet_guard._state import DayLog

__all__ = [
    "read_raw_log",
    "resign_entry",
    "undo_last_today",
    "write_raw_log",
]


def read_raw_log() -> DayLog:
    """Return the log exactly as stored, including tombstoned/invalid entries.

    Public counterpart of :func:`_read_raw_log`, for the sync orchestration
    (:mod:`diet_guard._sync`), which must see tombstones to merge them (the
    filtered :func:`load_log` drops them) and must not discard an entry that
    fails verification just because a phone-origin copy was never signed.
    """
    return _read_raw_log()


def write_raw_log(log: DayLog) -> None:
    """Persist ``log`` verbatim, overwriting the file on disk.

    Public counterpart of :func:`_write_log`, for :mod:`diet_guard._sync` to
    write back a merged log after re-signing it.
    """
    _write_log(log)


def resign_entry(entry: dict[str, object]) -> dict[str, object]:
    """Return a copy of ``entry`` with a freshly computed ``hmac``.

    Strips any existing signature first, mirroring :func:`undo_last_today`:
    a signature computed on another device (or none, if the phone -- which
    never holds the shared key -- produced this entry) cannot be trusted
    as-is, and recomputing is the only way :func:`_entry_is_valid` will
    accept it back on the next read.  A no-op (signature-wise) when no HMAC
    key is available locally, matching :func:`log_meal`'s degrade-gracefully
    behavior.

    Args:
        entry: A log entry, signed or not.

    Returns:
        A new dict equal to ``entry`` except for its ``hmac`` field.
    """
    resigned = dict(entry)
    resigned.pop("hmac", None)
    signature = compute_entry_hmac(resigned)
    if signature is not None:
        resigned["hmac"] = signature
    return resigned


def undo_last_today() -> dict[str, object] | None:
    """Tombstone today's most recently logged, not-yet-undone entry.

    Marks the entry ``deleted`` in place and re-signs it, rather than
    physically removing it: a sync merge with another device only ever
    *adds* entries it hasn't seen before, so a physical delete here would be
    silently resurrected the next time that device's stale copy is pulled
    back in.  The tombstone travels with the entry instead, and every reader
    (:func:`load_log`, the food-bank rebuild) already skips it.

    Operates on the raw log so a mistaken entry can always be undone, even
    one that would not pass verification.

    Returns:
        The tombstoned entry, or None if nothing undoable was logged today.
    """
    log = _read_raw_log()
    today = _today()
    entries = log.get(today)
    if not entries:
        return None
    for entry in reversed(entries):
        if entry.get("deleted"):
            continue
        entry["deleted"] = True
        entry.pop("hmac", None)
        signature = compute_entry_hmac(entry)
        if signature is not None:
            entry["hmac"] = signature
        _write_log(log)
        return entry
    return None
