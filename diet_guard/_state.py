"""HMAC-signed daily food log for diet_guard.

Each meal is stored as an individually HMAC-signed entry, reusing the shared
key at ``/etc/workout-locker/hmac.key`` -- the same key the screen locker uses
-- so the log is tamper-evident: editing the JSON to fake compliance
invalidates the signature.  On a system without the shared key, entries are
written unsigned and still accepted on read, so the tool degrades gracefully
instead of silently losing the data it just wrote.
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
import logging
import os
from typing import TYPE_CHECKING
import uuid

from gatelock.log_integrity import (
    compute_entry_hmac,
    verify_entry_hmac,
)

from diet_guard._budget import daily_budget
from diet_guard._coerce import as_float
from diet_guard._constants import BUDGET_WARN_FRACTION, FOOD_LOG_FILE

if TYPE_CHECKING:
    from diet_guard._estimator import Nutrition

_logger = logging.getLogger(__name__)

# On-disk shape: {"YYYY-MM-DD": [entry, entry, ...]}, newest entry last.
DayLog = dict[str, list[dict[str, object]]]


def now_local() -> datetime:
    """Return the current time as a timezone-aware local datetime."""
    return datetime.now(tz=timezone.utc).astimezone()


def _today() -> str:
    """Return today's *local* date as ``YYYY-MM-DD``.

    Local, not UTC: "what I ate today" is a local-calendar concept, and a meal
    eaten late in the evening must not roll into tomorrow's budget.
    """
    return now_local().date().isoformat()


def _entry_float(entry: dict[str, object], key: str) -> float:
    """Return ``entry[key]`` coerced to float (0.0 if missing/non-numeric).

    ``bool`` is rejected even though it subclasses ``int``: a boolean stored in
    a calorie or macro field is meaningless and must not count as 1 gram.

    Args:
        entry: A stored log entry.
        key: The numeric field name to read.

    Returns:
        The field as a float, or 0.0 when absent or not a real number.
    """
    return as_float(entry.get(key))


def entry_kcal(entry: dict[str, object]) -> float:
    """Return an entry's calorie count as a float (0.0 if missing/invalid)."""
    return _entry_float(entry, "kcal")


def _read_raw_log() -> DayLog:
    """Read the log file without verification (empty dict on any error)."""
    if not FOOD_LOG_FILE.exists():
        return {}
    try:
        with FOOD_LOG_FILE.open() as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        _logger.warning("Cannot read food log %s", FOOD_LOG_FILE)
        return {}
    if not isinstance(data, dict):
        return {}
    result: DayLog = {}
    for key, value in data.items():
        if isinstance(key, str) and isinstance(value, list):
            result[key] = [item for item in value if isinstance(item, dict)]
    return result


def _write_log(log: DayLog) -> None:
    """Persist the full log to disk, creating the data directory if needed.

    Written atomically -- a temp file in the same directory, then
    :func:`os.replace` -- so a concurrent reader (the gate now syncs while the
    15-min timer may also be writing) never sees a half-written file and
    mistakes a torn read for an empty log.
    """
    FOOD_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = FOOD_LOG_FILE.with_name(f"{FOOD_LOG_FILE.name}.{os.getpid()}.tmp")
    try:
        with tmp_path.open("w") as handle:
            json.dump(log, handle, indent=2)
        tmp_path.replace(FOOD_LOG_FILE)
    finally:
        tmp_path.unlink(missing_ok=True)


def _hmac_key_available() -> bool:
    """Return True if the shared HMAC key can be loaded for signing."""
    return compute_entry_hmac({"_probe": True}) is not None


def _entry_is_valid(entry: dict[str, object]) -> bool:
    """Return True if an entry is untampered.

    A signed entry must verify against the shared key.  An unsigned entry is
    accepted only when no key is available at all; an unsigned entry on a
    system that *does* have a key means someone stripped the signature to
    cheat, so it is rejected.
    """
    if isinstance(entry.get("hmac"), str):
        return verify_entry_hmac(entry)
    return not _hmac_key_available()


def log_meal(
    description: str,
    nutrition: Nutrition,
    slot: int | None = None,
    *,
    components: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    """Append a signed entry for ``description`` to today's log.

    Args:
        description: The user's free-text meal description.
        nutrition: Estimated nutrition for the portion eaten.
        slot: The meal-slot hour this entry satisfies (e.g. ``12`` for the
            12:00 checkpoint).  When None the entry still counts toward the
            day's calories but does not mark any slot as logged.
        components: For a composite (multi-item) meal, each component's own
            name and macros.  Carried on the log entry itself -- not just the
            food bank -- so a bank rebuilt purely by replaying the log (the
            companion phone app's sync model) can recover every component's
            standalone nutrition, not just the composite's summed total.

    Returns:
        The stored entry dict (carrying an ``hmac`` field when a key exists).
    """
    entry: dict[str, object] = {
        "id": str(uuid.uuid4()),
        "time": now_local().isoformat(timespec="seconds"),
        "desc": description,
        "grams": nutrition.grams,
        "kcal": nutrition.kcal,
        "protein_g": nutrition.protein_g,
        "carbs_g": nutrition.carbs_g,
        "fat_g": nutrition.fat_g,
        "source": nutrition.source,
    }
    if slot is not None:
        entry["slot"] = slot
    if components is not None:
        entry["components"] = list(components)
    signature = compute_entry_hmac(entry)
    if signature is not None:
        entry["hmac"] = signature
    else:
        _logger.warning("HMAC key unavailable - logging unsigned entry")

    log = _read_raw_log()
    log.setdefault(_today(), []).append(entry)
    _write_log(log)
    return entry


def load_log() -> DayLog:
    """Return the log with only valid, non-deleted entries retained.

    A "deleted" entry is a tombstone left by :func:`undo_last_today`, not a
    removal: it is kept on disk (and re-signed) rather than popped, so a sync
    merge with another device can see the tombstone and not resurrect a
    stale copy of the same entry.  Readers simply filter it out here.
    """
    raw = _read_raw_log()
    verified: DayLog = {}
    for day, entries in raw.items():
        kept = [
            entry
            for entry in entries
            if _entry_is_valid(entry) and not entry.get("deleted")
        ]
        if kept:
            verified[day] = kept
    return verified


def today_entries() -> list[dict[str, object]]:
    """Return today's valid log entries (possibly empty)."""
    return load_log().get(_today(), [])


def today_total_kcal() -> float:
    """Return total kcal logged today across valid entries."""
    total = sum(entry_kcal(entry) for entry in today_entries())
    return round(total, 1)


def today_total_macros() -> tuple[float, float, float]:
    """Return today's total ``(protein_g, carbs_g, fat_g)`` across valid entries.

    Returned as a fixed ``(protein, carbs, fat)`` triple so callers (the gate
    dashboard, the CLI status) can show how the day's macros are stacking up
    next to the calorie total.

    Returns:
        The summed protein, carbohydrate, and fat grams, each rounded to 0.1 g.
    """
    entries = today_entries()
    protein = sum(_entry_float(entry, "protein_g") for entry in entries)
    carbs = sum(_entry_float(entry, "carbs_g") for entry in entries)
    fat = sum(_entry_float(entry, "fat_g") for entry in entries)
    return round(protein, 1), round(carbs, 1), round(fat, 1)


def logged_slots_today() -> set[int]:
    """Return the set of meal-slot hours already covered by today's log.

    Only valid (HMAC-verified) entries count, so stripping entries to dodge a
    checkpoint makes that slot reappear as unsatisfied -- the fail-closed
    direction.  An entry without a ``slot`` field (e.g. a snack logged with no
    checkpoint) contributes calories but satisfies no slot.

    Returns:
        The distinct integer slot hours logged today (possibly empty).
    """
    slots: set[int] = set()
    for entry in today_entries():
        value = entry.get("slot")
        if isinstance(value, int) and not isinstance(value, bool):
            slots.add(value)
    return slots


def remaining_budget() -> float:
    """Return kcal remaining against the sealed budget (may be negative).

    Raises:
        BudgetError: If the budget is uninitialized or its seal is broken;
            the caller decides whether to guide the user or fail closed.
    """
    return round(daily_budget() - today_total_kcal(), 1)


def consumption_band() -> str:
    """Return a qualitative band for today's intake, never revealing the budget.

    Mirrors how the focus daemon surfaces "at home?" rather than the raw
    coordinates: the caller learns whether to worry, not the number behind the
    threshold.  The threshold still leaks by boundary-probing (watch the label
    flip), so this hides the anchor, it does not make the budget unrecoverable.

    Returns:
        ``"OVER BUDGET"``, ``"approaching limit"``, or ``"on track"``.

    Raises:
        BudgetError: Propagated from :func:`daily_budget` for the caller to
            translate into guidance.
    """
    budget = daily_budget()
    consumed = today_total_kcal()
    if consumed >= budget:
        return "OVER BUDGET"
    if consumed >= budget * BUDGET_WARN_FRACTION:
        return "approaching limit"
    return "on track"


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
