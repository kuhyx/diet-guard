"""Meal-schedule history as extra fields on the shared ``budget`` record.

Split out of :mod:`._budget` to keep both modules under the repo's 250-line
limit; the two halves are otherwise the same idea and share one record.

The schedule rides as one ``sched:<YYYY-MM-DD>`` field per history entry,
exactly like the budget's ``hist:`` fields.  ``crdt_sync``'s ``merge_record``
is per-field last-writer-wins over the *union* of field names, and both
devices push the *merged* record rather than their own, so a device that
predates meal schedules neither clobbers those fields nor blocks them -- it
relays them untouched.  That is what makes this shippable without a
coordinated release.

The value is a small map (``{"f": 8, "l": 20, "n": 5}``) rather than a scalar.
``Record.to_dict``/``from_dict`` round-trip nested values unchanged, and a
malformed one is skipped exactly as a non-int ``hist:`` value is.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import TYPE_CHECKING

from crdt_sync import Hlc

from diet_guard._device import device_id
from diet_guard._meal_schedule import MealSchedule
from diet_guard._meal_schedule_store import ScheduleEntry
from diet_guard.sync_merge._clock import _EPOCH

if TYPE_CHECKING:
    from crdt_sync import Log

_BUDGET_RECORD_ID = "budget"
# Field-name prefix for the effective-from meal-schedule history, one field
# per date.  A separate *field* rather than a separate document, for the
# reason spelled out in this module's docstring.
SCHEDULE_FIELD_PREFIX = "sched:"


def schedule_hlc(entry: ScheduleEntry) -> Hlc:
    """Derive a deterministic Hlc for one schedule entry from its edit time.

    Same trick as the budget's ``_history_hlc``: identical inputs always yield
    the same clock, so re-syncing an unchanged history is a no-op.  Derived
    from the parsed timestamp rather than the raw string, so the two languages
    agree even though they format the epoch fallback differently.
    """
    try:
        moment = datetime.fromisoformat(entry.edited_at)
    except ValueError:
        moment = _EPOCH
    return Hlc.new_tick(device_id(), wall_time_ms=int(moment.timestamp() * 1000))


def schedule_fields(
    entries: tuple[ScheduleEntry, ...],
) -> dict[str, tuple[object, Hlc]]:
    """Return the ``sched:`` fields contributed by ``entries``.

    Empty when this device has no history, so a device that has never edited
    a schedule contributes nothing to the merge rather than pushing the unset
    default over a peer's real value.
    """
    return {
        f"{SCHEDULE_FIELD_PREFIX}{entry.effective_from}": (
            {
                "f": entry.schedule.first,
                "l": entry.schedule.last,
                "n": entry.schedule.count,
            },
            schedule_hlc(entry),
        )
        for entry in entries
    }


def log_to_schedule_history(log: Log) -> tuple[ScheduleEntry, ...]:
    """Extract the meal-schedule history from a merged budget ``Log``.

    Each entry's ``edited_at`` is reconstructed from its field Hlc rather than
    carried separately, so the stored timestamp and the clock the merge
    compared can never drift apart.  Malformed values are skipped, so one bad
    field from a peer cannot take out the whole history.
    """
    record = log.get(_BUDGET_RECORD_ID)
    if record is None:
        return ()
    entries = []
    for name, (value, hlc) in record.fields.items():
        if not name.startswith(SCHEDULE_FIELD_PREFIX):
            continue
        if not isinstance(value, dict):
            continue
        first, last, count = value.get("f"), value.get("l"), value.get("n")
        if not (
            isinstance(first, int) and isinstance(last, int) and isinstance(count, int)
        ) or any(isinstance(part, bool) for part in (first, last, count)):
            continue
        edited = datetime.fromtimestamp(hlc.wall_time_ms / 1000, tz=timezone.utc)
        entries.append(
            ScheduleEntry(
                effective_from=name[len(SCHEDULE_FIELD_PREFIX) :],
                # Normalised on the way in, so a peer running a future version
                # with a wider range cannot hand us a schedule we would derive
                # slots differently from.
                schedule=MealSchedule(first, last, count).normalized(),
                edited_at=edited.astimezone().isoformat(timespec="seconds"),
            ),
        )
    return tuple(sorted(entries, key=lambda entry: entry.effective_from))
