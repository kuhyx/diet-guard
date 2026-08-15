"""Effective-from history of the daily kcal budget.

The budget is a single, freely-editable number (see :mod:`diet_guard._budget`),
but *classifying a past day* must use the budget that applied on that day --
otherwise lowering the budget silently reclassifies months of history, breaking
the adherence streak and the year-to-date tally for days that were in fact
adherent at the time.

The history is a forward-only list of ``(effective_from, kcal)`` entries.  The
budget for a day is the newest entry whose ``effective_from`` is on or before
it.  Editing the budget appends (or, for a same-day re-edit, replaces) the
entry for that day; every earlier day keeps whatever applied then.

Storage and sync are deliberately split:

* the entries live in their own file (``.budget_history``), leaving
  :mod:`diet_guard._budget`'s ``.budget`` schema untouched at v2;
* they travel as extra ``hist:<YYYY-MM-DD>`` *fields* on the existing
  ``budget`` CRDT record (see :mod:`diet_guard.sync_merge`).

That second point is the load-bearing one.  ``crdt_sync``'s ``merge_record``
does per-field last-writer-wins over the *union* of field names, and both
devices push the merged record rather than their own, so a device that knows
nothing about history can neither clobber those fields nor stop them
propagating -- it relays them untouched.  No coordinated release is needed.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import json
import logging

from diet_guard._constants import BUDGET_HISTORY_FILE

_logger = logging.getLogger(__name__)

_FILE_VERSION = 1

# The effective-from date the migration seeds, so the pre-history budget
# covers every day that was ever logged.  Any real date is >= this.
EPOCH_DAY = "1970-01-01"

_EPOCH_ISO = "1970-01-01T00:00:00+00:00"


@dataclass(frozen=True)
class BudgetEntry:
    """One budget value and the date it started applying.

    Attributes:
        effective_from: ``YYYY-MM-DD``; the first day this value applies to.
        kcal: The daily budget in kcal from that day onward.
        edited_at: Local ISO-8601 timestamp of the edit that created it, used
            to derive a deterministic Hlc for the sync merge.
    """

    effective_from: str
    kcal: int
    edited_at: str


@dataclass(frozen=True)
class BudgetSchedule:
    """The budget as a function of the day, with a fallback for empty history.

    Attributes:
        entries: Ascending by ``effective_from``.
        default: Used when no entry applies -- an unset device, or a day
            before the earliest entry.  In practice the second case never
            arises, since the migration always seeds :data:`EPOCH_DAY`.
    """

    entries: tuple[BudgetEntry, ...]
    default: int

    def for_day(self, day: str) -> int:
        """Return the budget that applied on ``day`` (a ``YYYY-MM-DD`` key)."""
        applicable = [e for e in self.entries if e.effective_from <= day]
        if not applicable:
            return self.default
        return applicable[-1].kcal


def history_from_json(raw: object) -> tuple[BudgetEntry, ...]:
    """Parse a stored history document, tolerating anything malformed.

    Deliberately single-branched on bad input: a corrupt or unrecognised
    history degrades to "no history", which callers already handle by falling
    back to the current scalar budget.  Every extra rejection branch would be
    another branch the 100%-coverage gate has to reach for no behavioural gain.

    Args:
        raw: The parsed JSON document, of any shape.

    Returns:
        The entries, ascending by ``effective_from`` (empty if unusable).
    """
    if not isinstance(raw, dict) or raw.get("v") != _FILE_VERSION:
        return ()
    stored = raw.get("e")
    if not isinstance(stored, dict):
        return ()
    entries = []
    for day, record in stored.items():
        if not isinstance(record, dict):
            continue
        kcal = record.get("b")
        if isinstance(kcal, bool) or not isinstance(kcal, int):
            continue
        edited_at = record.get("t")
        entries.append(
            BudgetEntry(
                effective_from=str(day),
                kcal=kcal,
                edited_at=edited_at if isinstance(edited_at, str) else _EPOCH_ISO,
            ),
        )
    return tuple(sorted(entries, key=lambda e: e.effective_from))


def history_to_json(entries: tuple[BudgetEntry, ...]) -> dict[str, object]:
    """Serialize ``entries`` to the stored document shape."""
    return {
        "v": _FILE_VERSION,
        "e": {e.effective_from: {"b": e.kcal, "t": e.edited_at} for e in entries},
    }


def upsert(
    entries: tuple[BudgetEntry, ...],
    *,
    kcal: int,
    when: datetime,
) -> tuple[BudgetEntry, ...]:
    """Return ``entries`` with ``when``'s date set to ``kcal``.

    Keyed on the date, so editing the budget twice in one day replaces that
    day's entry instead of accumulating duplicates.

    Args:
        entries: The current history.
        kcal: The new budget value.
        when: The edit time; its local date becomes ``effective_from``.

    Returns:
        The updated history, ascending by ``effective_from``.
    """
    day = when.date().isoformat()
    kept = [e for e in entries if e.effective_from != day]
    kept.append(
        BudgetEntry(
            effective_from=day,
            kcal=int(kcal),
            edited_at=when.isoformat(timespec="seconds"),
        ),
    )
    return tuple(sorted(kept, key=lambda e: e.effective_from))


def seed_from_budget(record: dict[str, object] | None) -> tuple[BudgetEntry, ...]:
    """Return the one-entry history that grandfathers an existing budget.

    The pre-history budget is treated as having applied since
    :data:`EPOCH_DAY`, so every already-logged day keeps the value it was
    actually judged against.  Reuses the record's own ``t`` rather than "now",
    which is what lets two devices seed independently and still converge: both
    derive the same value at the same Hlc wall time.

    Args:
        record: The raw ``.budget`` record, or None if never initialised.

    Returns:
        A single-entry history, or empty when there is no budget to grandfather.
    """
    if record is None:
        return ()
    kcal = record.get("b")
    if isinstance(kcal, bool) or not isinstance(kcal, int):
        return ()
    edited_at = record.get("t")
    return (
        BudgetEntry(
            effective_from=EPOCH_DAY,
            kcal=kcal,
            edited_at=edited_at if isinstance(edited_at, str) else _EPOCH_ISO,
        ),
    )


def read_raw_history() -> dict[str, object] | None:
    """Return the on-disk history document verbatim, or None if absent/corrupt.

    Never raises: an unreadable history means "fall back to the scalar
    budget", which is exactly the pre-history behaviour.
    """
    if not BUDGET_HISTORY_FILE.exists():
        return None
    try:
        with BUDGET_HISTORY_FILE.open() as handle:
            document = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(document, dict):
        return None
    return document


def write_raw_history(document: dict[str, object]) -> None:
    """Persist ``document`` verbatim, overwriting the history file."""
    BUDGET_HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    with BUDGET_HISTORY_FILE.open("w") as handle:
        json.dump(document, handle)


def load_entries() -> tuple[BudgetEntry, ...]:
    """Return the stored history, or empty if none has been written yet.

    Deliberately does not reach into :mod:`diet_guard._budget` to lazily seed:
    that would be a circular import, and it would hide *where* seeding happens.
    Seeding lives in :func:`diet_guard._budget.current_schedule` and
    :func:`diet_guard._budget.write_budget`, which own the value being
    grandfathered.
    """
    raw = read_raw_history()
    return () if raw is None else history_from_json(raw)


def record_budget_change(kcal: int, *, when: datetime | None = None) -> None:
    """Record a budget edit, effective from the day it was made."""
    moment = when if when is not None else datetime.now(tz=timezone.utc).astimezone()
    write_raw_history(history_to_json(upsert(load_entries(), kcal=kcal, when=moment)))
