"""Forward-only history of the user's meal schedule, and its persistence.

The schedule is freely editable on either device, but *judging a past day* must
use the schedule that applied on that day.  Otherwise switching from four meals
to five would retroactively mark every earlier day as having missed a
checkpoint.

The shape is deliberately the same as :mod:`diet_guard._budget_history`: a
forward-only list of ``(effective_from, schedule)`` entries, where the schedule
for a day is the newest entry whose ``effective_from`` is on or before it.
Editing appends (or, for a same-day re-edit, replaces) that day's entry, and
every earlier day keeps whatever applied then.

Storage and sync are split the same way too:

* the entries live in their own file (``.meal_schedule``);
* they travel as extra ``sched:<YYYY-MM-DD>`` *fields* on the existing
  ``budget`` CRDT record (see :mod:`diet_guard.sync_merge`).

That second point is what makes this shippable without a coordinated release:
``merge_record`` does per-field last-writer-wins over the *union* of field
names, and both devices push the merged record rather than their own, so a
device that knows nothing about meal schedules can neither clobber those fields
nor stop them propagating -- it relays them untouched.

KEEP IN SYNC WITH ``app/lib/services/meal_schedule_service.dart``.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
import json
import logging

from diet_guard._constants import MEAL_SCHEDULE_FILE
from diet_guard._meal_schedule import DEFAULT_SCHEDULE, MealSchedule

_logger = logging.getLogger(__name__)

_FILE_VERSION = 1

# The effective-from date a seed uses, so the pre-history schedule covers every
# day that was ever logged.  Any real date is >= this.
EPOCH_DAY = "1970-01-01"

_EPOCH_ISO = "1970-01-01T00:00:00+00:00"


@dataclass(frozen=True)
class ScheduleEntry:
    """One meal schedule and the date it started applying.

    Attributes:
        effective_from: ``YYYY-MM-DD``; the first day this schedule applies to.
        schedule: The eating window and meal count from that day onward.
        edited_at: Local ISO-8601 timestamp of the edit that created it, used
            to derive a deterministic Hlc for the sync merge.
    """

    effective_from: str
    schedule: MealSchedule
    edited_at: str


def entry_to_json(entry: ScheduleEntry) -> dict[str, object]:
    """Return the wire/disk form of one entry's value."""
    return {
        "f": entry.schedule.first,
        "l": entry.schedule.last,
        "n": entry.schedule.count,
        "t": entry.edited_at,
    }


def entry_from_json(effective_from: str, raw: object) -> ScheduleEntry | None:
    """Return an entry parsed from its stored value, or None if unusable.

    Never raises: a malformed entry is skipped so one bad field from a peer
    cannot take out the whole history.
    """
    if not isinstance(raw, dict):
        return None
    first, last, count = raw.get("f"), raw.get("l"), raw.get("n")
    if not (
        isinstance(first, int) and isinstance(last, int) and isinstance(count, int)
    ):
        return None
    edited_at = raw.get("t")
    return ScheduleEntry(
        effective_from=effective_from,
        # Normalising on the way in means a peer running a future version with
        # a wider range cannot hand us a schedule we would derive differently.
        schedule=MealSchedule(first, last, count).normalized(),
        edited_at=edited_at if isinstance(edited_at, str) else _EPOCH_ISO,
    )


def history_from_json(raw: object) -> tuple[ScheduleEntry, ...]:
    """Return the entries in a stored document, ascending by date.

    Anything unreadable yields no entries, which callers treat as "fall back
    to the default schedule" -- the pre-feature behaviour.
    """
    if not isinstance(raw, dict):
        return ()
    entries = raw.get("e")
    if not isinstance(entries, dict):
        return ()
    parsed = [
        entry
        for day, value in entries.items()
        if isinstance(day, str) and (entry := entry_from_json(day, value)) is not None
    ]
    return tuple(sorted(parsed, key=lambda entry: entry.effective_from))


def history_to_json(entries: tuple[ScheduleEntry, ...]) -> dict[str, object]:
    """Return the on-disk document for ``entries``."""
    return {
        "v": _FILE_VERSION,
        "e": {entry.effective_from: entry_to_json(entry) for entry in entries},
    }


def schedule_for_day(entries: tuple[ScheduleEntry, ...], day: str) -> MealSchedule:
    """Return the schedule in force on ``day``.

    Args:
        entries: The history, ascending by ``effective_from``.
        day: ``YYYY-MM-DD``.

    Returns:
        The newest entry effective on or before ``day``, or the default when
        the history says nothing about that day.
    """
    applicable = [entry for entry in entries if entry.effective_from <= day]
    return applicable[-1].schedule if applicable else DEFAULT_SCHEDULE


def upsert(
    entries: tuple[ScheduleEntry, ...],
    schedule: MealSchedule,
    when: datetime,
) -> tuple[ScheduleEntry, ...]:
    """Return ``entries`` with ``schedule`` effective from ``when``'s date.

    Re-editing on the same day replaces that day's entry rather than stacking
    a second one, so the history holds at most one entry per date.
    """
    day = when.date().isoformat()
    kept = tuple(entry for entry in entries if entry.effective_from != day)
    fresh = ScheduleEntry(
        effective_from=day,
        schedule=schedule.normalized(),
        edited_at=when.isoformat(),
    )
    return tuple(sorted((*kept, fresh), key=lambda entry: entry.effective_from))


def seed_default(entries: tuple[ScheduleEntry, ...]) -> tuple[ScheduleEntry, ...]:
    """Return ``entries`` with the default schedule pinned to the epoch.

    Recording today's schedule without this would leave every *earlier* day
    with no applicable entry, and those days would then adopt whatever the
    user just chose -- exactly the retroactive reclassification the history
    exists to prevent.  Callers must seed **before** recording today's value.
    """
    if any(entry.effective_from == EPOCH_DAY for entry in entries):
        return entries
    seeded = ScheduleEntry(
        effective_from=EPOCH_DAY,
        schedule=DEFAULT_SCHEDULE,
        edited_at=_EPOCH_ISO,
    )
    return tuple(sorted((seeded, *entries), key=lambda entry: entry.effective_from))


def read_raw_history() -> dict[str, object] | None:
    """Return the on-disk document verbatim, or None if absent/corrupt.

    Never raises: an unreadable history means "use the default schedule",
    which is the pre-feature behaviour.
    """
    if not MEAL_SCHEDULE_FILE.exists():
        return None
    try:
        with MEAL_SCHEDULE_FILE.open() as handle:
            document = json.load(handle)
    except OSError, json.JSONDecodeError:
        _logger.debug("unreadable meal schedule; using the default")
        return None
    if not isinstance(document, dict):
        return None
    return document


def write_raw_history(document: dict[str, object]) -> None:
    """Persist ``document`` verbatim, overwriting the schedule file."""
    MEAL_SCHEDULE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with MEAL_SCHEDULE_FILE.open("w") as handle:
        json.dump(document, handle)


def load_entries() -> tuple[ScheduleEntry, ...]:
    """Return the stored history, or empty if none has been written yet."""
    raw = read_raw_history()
    return () if raw is None else history_from_json(raw)


def current_schedule() -> MealSchedule:
    """Return the schedule in force today.

    This is the impure edge every :mod:`diet_guard._slots` caller resolves
    through; the slot arithmetic itself stays a pure function of its
    arguments.
    """
    today = datetime.now(tz=UTC).astimezone().date().isoformat()
    return schedule_for_day(load_entries(), today)


def record_schedule_change(
    schedule: MealSchedule, *, when: datetime | None = None
) -> None:
    """Record a schedule edit, effective from the day it was made.

    Seeds the default at the epoch first, so past days keep the four-meal
    schedule they were actually judged against.
    """
    moment = when if when is not None else datetime.now(tz=UTC).astimezone()
    entries = seed_default(load_entries())
    write_raw_history(history_to_json(upsert(entries, schedule, moment)))
