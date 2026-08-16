"""Budget and budget-history <-> ``crdt_sync.Record`` adapters.

Same ``Record``/``Log`` shape as the food-log adapters, with one important
difference: a budget record is edited repeatedly rather than being immutable
after creation, so its ``Hlc`` derives from a ``t`` edit timestamp that
:func:`diet_guard._budget.write_budget` bumps on every write, not from a birth
time that never changes.

History rides along as ``hist:<YYYY-MM-DD>`` *fields* on the same record
rather than as a second document, so a device predating the feature relays
those fields untouched. There is no legacy fallback -- ``budget.json`` is a
brand-new sync payload, so every device pushing it already speaks this format.
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
from typing import TYPE_CHECKING

from crdt_sync import Hlc, Record

from diet_guard._budget_history import BudgetEntry
from diet_guard._device import device_id
from diet_guard.sync_merge._clock import _EPOCH
from diet_guard.sync_merge._schedule import schedule_fields

if TYPE_CHECKING:
    from crdt_sync import Log

    from diet_guard._meal_schedule_store import ScheduleEntry


_BUDGET_RECORD_ID = "budget"
# Field-name prefix for the effective-from budget history, one field per date.
# A separate *field* rather than a separate document, because merge_record
# unions field names -- see budget_to_log.
_HISTORY_FIELD_PREFIX = "hist:"
# Body weight, as its own field rather than a key inside ``value``.  It is
# shared state like everything else -- both devices must see one value -- but
# it needs its own Hlc so a device that never sets it (the phone) cannot
# delete it merely by pushing a budget edit.
_WEIGHT_FIELD = "weight"


def _budget_hlc(record: dict[str, object]) -> Hlc:
    """Derive a deterministic Hlc for a raw budget record from its ``t`` field.

    Mirrors :func:`_entry_hlc`'s determinism -- the same unedited record
    always yields the same Hlc, so re-syncing an unchanged budget is a
    no-op -- but reads ``t`` (bumped on every :func:`diet_guard._budget.
    write_budget` call) rather than a fixed birth time, since a budget can
    be edited repeatedly and the *edit* time is what last-writer-wins must
    compare.
    """
    try:
        dt = datetime.fromisoformat(str(record.get("t", "")))
    except ValueError:
        dt = _EPOCH
    wall_time_ms = int(dt.timestamp() * 1000)
    return Hlc.new_tick(device_id(), wall_time_ms=wall_time_ms)


def _history_hlc(entry: BudgetEntry) -> Hlc:
    """Derive a deterministic Hlc for one history entry from its edit time.

    Same trick as :func:`_budget_hlc`: identical inputs always yield the same
    clock, so re-syncing unchanged history is a no-op.  Two devices that seed
    the history independently derive the same ``wall_time_ms`` and the same
    value and differ only in node id, so whichever side wins the field-level
    LWW, the value is identical and the merge converges in one round.
    """
    try:
        moment = datetime.fromisoformat(entry.edited_at)
    except ValueError:
        moment = _EPOCH
    return Hlc.new_tick(device_id(), wall_time_ms=int(moment.timestamp() * 1000))


def budget_to_log(
    record: dict[str, object] | None,
    entries: tuple[BudgetEntry, ...] = (),
    schedule_entries: tuple[ScheduleEntry, ...] = (),
) -> Log:
    """Convert a raw local budget record plus its history into a Log.

    Returns an empty ``Log`` when ``record`` is None (this device has never
    run ``init``), so an uninitialized device contributes nothing to the
    merge rather than clobbering another device's real value.

    The history rides along as one ``hist:<YYYY-MM-DD>`` field per entry on
    the *same* record.  ``crdt_sync``'s ``merge_record`` is per-field LWW over
    the union of field names, so a device that predates the history neither
    clobbers those fields nor blocks them: it merges them in from the remote
    and pushes them straight back out (both sides push the *merged* log).
    That is what makes this safe to roll out without a coordinated release.

    ``w`` (body weight) travels the same way, as its own :data:`_WEIGHT_FIELD`
    rather than as a key inside ``value``.  It is shared state -- both devices
    must agree on it -- but inside ``value`` it was collateral damage of the
    whole-map LWW: the phone rebuilds that map without ``w``, so any phone
    budget edit silently deleted the stored weight and with it the protein
    target.  As its own field it is protected by per-field LWW, and a device
    that never sets it relays it untouched instead of dropping it.
    """
    if record is None:
        return {}
    hlc = _budget_hlc(record)
    value = {k: v for k, v in record.items() if k not in {"t", "w"}}
    fields: dict[str, tuple[object, Hlc]] = {"value": (value, hlc)}
    weight = record.get("w")
    if isinstance(weight, (int, float)) and not isinstance(weight, bool):
        fields[_WEIGHT_FIELD] = (float(weight), hlc)
    for entry in entries:
        fields[f"{_HISTORY_FIELD_PREFIX}{entry.effective_from}"] = (
            entry.kcal,
            _history_hlc(entry),
        )
    # The meal-schedule history rides the same record as its own `sched:`
    # fields; see :mod:`diet_guard.sync_merge._schedule`.
    fields.update(schedule_fields(schedule_entries))
    rec = Record(id=_BUDGET_RECORD_ID, fields=fields)
    return {rec.id: rec}


def log_to_history(log: Log) -> tuple[BudgetEntry, ...]:
    """Extract the effective-from history from a merged budget ``Log``.

    Each entry's ``edited_at`` is reconstructed from its field Hlc rather than
    carried separately, so the stored timestamp and the clock the merge
    compared can never drift apart.
    """
    record = log.get(_BUDGET_RECORD_ID)
    if record is None:
        return ()
    entries = []
    for name, (value, hlc) in record.fields.items():
        if not name.startswith(_HISTORY_FIELD_PREFIX):
            continue
        if isinstance(value, bool) or not isinstance(value, int):
            continue
        edited = datetime.fromtimestamp(hlc.wall_time_ms / 1000, tz=timezone.utc)
        entries.append(
            BudgetEntry(
                effective_from=name[len(_HISTORY_FIELD_PREFIX) :],
                kcal=value,
                edited_at=edited.astimezone().isoformat(timespec="seconds"),
            ),
        )
    return tuple(sorted(entries, key=lambda e: e.effective_from))


def log_to_budget(log: Log) -> dict[str, object] | None:
    """Convert a merged budget ``Log`` back into a raw budget record.

    Returns None when the log has no budget record at all (neither device
    has ever run ``init`` yet) -- callers treat that as "nothing to write
    locally", not an error.
    """
    record = log.get(_BUDGET_RECORD_ID)
    if record is None:
        return None
    value, hlc = record.fields.get("value", ({}, None))
    result: dict[str, object] = dict(value) if isinstance(value, dict) else {}
    if hlc is not None:
        winning_time = datetime.fromtimestamp(hlc.wall_time_ms / 1000, tz=timezone.utc)
        result["t"] = winning_time.astimezone().isoformat(timespec="seconds")
    weight, _ = record.fields.get(_WEIGHT_FIELD, (None, None))
    if isinstance(weight, (int, float)) and not isinstance(weight, bool):
        result["w"] = float(weight)
    return result


def parse_remote_budget(text: str) -> Log:
    """Parse one device's pushed ``budget.json`` text into a ``crdt_sync.Log``.

    Raises on malformed data; the caller
    (:func:`diet_guard._sync._pull_remote_budgets`) logs-and-skips on that,
    matching :func:`parse_remote_log`'s tolerance for a bad device file.

    Raises:
        TypeError: If the top-level JSON isn't an object, or a record value
            isn't shaped as expected.
        KeyError: Via ``Record.from_dict``, if a record is missing an
            expected key.
        ValueError: Via ``json.loads`` on invalid JSON, or ``Hlc.from_str``
            on a malformed clock string.
    """
    raw = json.loads(text)
    if not isinstance(raw, dict):
        msg = f"top-level budget payload is not a JSON object: {raw!r}"
        raise TypeError(msg)
    return {record_id: Record.from_dict(data) for record_id, data in raw.items()}
