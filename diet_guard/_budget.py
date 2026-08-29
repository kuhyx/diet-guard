"""Freely-editable daily calorie budget for diet_guard.

The budget is computed once from biometrics at ``init`` time (via the same
Mifflin-St Jeor formula as before) and written to a plain JSON file in the
XDG data dir, but it is no longer sealed: it can be changed at any time, on
this machine or the phone app, with no special ritual. It syncs like the
food log (see :mod:`diet_guard._sync`), so the same current value is
available on both devices, last-edit-wins.

This is a deliberate design change from the file's previous ``chattr +i``
seal, which existed specifically to make impulsive "make room" edits
require a deliberate root step. That friction is gone by design; nothing in
this module tries to reintroduce it.

Everything here answers "what is the budget *now*".  "What was the budget on
2026-06-14?" is :mod:`diet_guard._budget_history`, which :func:`write_budget`
keeps up to date on every edit.
"""

from __future__ import annotations

from datetime import UTC, datetime
import json
import logging

from diet_guard._budget_history import (
    BudgetSchedule,
    history_to_json,
    load_entries,
    record_budget_change,
    seed_from_budget,
    write_raw_history,
)
from diet_guard._constants import BUDGET_FILE

_logger = logging.getLogger(__name__)

# Schema version stored in the file, so a future format change can be
# detected rather than silently misread. v2 adds the optional body weight
# (``w``) used to derive a protein target; v1 files (budget only) still
# read correctly.
_FILE_VERSION = 2


def _now_local() -> datetime:
    """Return the current time as a timezone-aware local datetime.

    Duplicated from :func:`diet_guard._state.now_local` rather than
    imported: ``_state`` imports :func:`daily_budget` from this module, so
    importing back from ``_state`` here would be circular.
    """
    return datetime.now(tz=UTC).astimezone()


# A medically sane lower bound.  Even an aggressive deficit must not compute
# a starvation-level target, so the value is floored here.
_MIN_SANE_BUDGET = 1200

# Daily protein target for an active adult holding muscle on a deficit, in
# grams per kg of body weight.  Used only to show a target in the dashboard;
# it has no part in the calorie budget maths.
PROTEIN_G_PER_KG = 1.8


class BudgetError(Exception):
    """Base class for all budget-access failures."""


class BudgetNotInitializedError(BudgetError):
    """Raised when no budget has been set yet (``init`` never run)."""

    def __init__(self) -> None:
        """Initialize with a fixed, side-effect-free message."""
        super().__init__("daily budget has not been initialized")


class BudgetFileCorruptError(BudgetError):
    """Raised when the budget file exists but cannot be read or parsed."""

    def __init__(self) -> None:
        """Initialize with a fixed, side-effect-free message."""
        super().__init__("daily budget file is corrupt")


def is_initialized() -> bool:
    """Return True if a budget file exists on disk."""
    return BUDGET_FILE.exists()


def _seed_history_if_empty(record: dict[str, object] | None) -> None:
    """Grandfather ``record``'s budget to the epoch if no history exists yet.

    Guards on the history being **empty**, not on the file being absent.  An
    empty-but-present document is reachable in normal operation -- notably
    :func:`diet_guard._sync._sync_budget` writing back a merge that carried no
    ``hist:`` fields (a pre-feature peer) -- and a presence-based guard would
    then never seed again, leaving a history of only ``{today: <new value>}``
    so every past day falls through to the *current* budget.  That is exactly
    the retroactive reclassification this module exists to prevent.
    """
    if load_entries():
        return
    seeded = seed_from_budget(record)
    if seeded:
        write_raw_history(history_to_json(seeded))


def current_schedule(*, default: int) -> BudgetSchedule:
    """Return the budget history as a schedule, seeding it if still empty.

    Lives here rather than in :mod:`diet_guard._budget_history` so the seeding
    logic sits with the module that owns the value being grandfathered; that
    also keeps ``_budget_history`` free of any import back into this module.
    """
    _seed_history_if_empty(read_raw_record())
    return BudgetSchedule(load_entries(), default=default)


def write_budget(value: int, *, weight_kg: float | None = None) -> None:
    """Write ``value`` as the daily kcal budget, plainly (no seal, no signing).

    Stamps a ``t`` edit timestamp on every write (unlike a food-log entry,
    the budget can be edited repeatedly, so :mod:`diet_guard._sync` needs to
    know *when* this write happened to resolve a last-edit-wins merge
    against another device's write).

    Also the single funnel that maintains the effective-from history (see
    :mod:`diet_guard._budget_history`), so past days keep being judged
    against the budget that applied to them.

    The ordering below is load-bearing and must not be rearranged: the
    *pre-write* record is grandfathered to :data:`EPOCH_DAY` **before** the
    new value is recorded for today.  Seeding afterwards would leave a
    history of only ``{today: <new value>}``, which makes every past day
    resolve to the new value -- precisely the retroactive reclassification
    the history exists to prevent.

    Args:
        value: The daily budget in kcal.
        weight_kg: Body weight in kg to store alongside the budget, so a
            protein target can later be derived. Optional; omitting it
            writes a budget-only record that reads back with no protein
            target.
    """
    existing = read_raw_record()
    _seed_history_if_empty(existing)
    record: dict[str, object] = {
        "v": _FILE_VERSION,
        "b": int(value),
        "t": _now_local().isoformat(timespec="seconds"),
    }
    if weight_kg is not None:
        record["w"] = round(float(weight_kg), 1)
    write_raw_record(record)
    record_budget_change(int(value))


def _read_record() -> dict[str, object]:
    """Read and parse the budget file.

    Returns:
        The parsed record dict (carrying ``b`` and, optionally, ``w``).

    Raises:
        BudgetNotInitializedError: If no budget has been set yet.
        BudgetFileCorruptError: If the file exists but cannot be parsed.
    """
    if not BUDGET_FILE.exists():
        raise BudgetNotInitializedError
    try:
        with BUDGET_FILE.open() as handle:
            record = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise BudgetFileCorruptError from exc
    if not isinstance(record, dict):
        raise BudgetFileCorruptError
    return record


def daily_budget() -> int:
    """Return the current daily kcal budget.

    Returns:
        The daily kcal budget.

    Raises:
        BudgetNotInitializedError: If no budget has been set yet.
        BudgetFileCorruptError: If the file exists but cannot be parsed.
    """
    record = _read_record()
    value = record.get("b")
    if isinstance(value, bool) or not isinstance(value, int):
        raise BudgetFileCorruptError
    return value


def read_raw_record() -> dict[str, object] | None:
    """Return the on-disk budget record verbatim, or None if unset/corrupt.

    Public, sync-only counterpart to :func:`_read_record`:
    :mod:`diet_guard._sync` must treat "not yet set" and "unreadable" alike
    as "nothing of this device's to contribute to the merge" rather than an
    error, so unlike :func:`daily_budget` this never raises.
    """
    if not BUDGET_FILE.exists():
        return None
    try:
        with BUDGET_FILE.open() as handle:
            record = json.load(handle)
    except OSError, json.JSONDecodeError:
        return None
    if not isinstance(record, dict):
        return None
    return record


def write_raw_record(record: dict[str, object]) -> None:
    """Persist ``record`` verbatim, overwriting the file on disk.

    Public counterpart to :func:`read_raw_record`, used by both
    :func:`write_budget` and :mod:`diet_guard._sync` (to write back a
    merged record, carrying the winning side's ``t`` edit timestamp).
    """
    BUDGET_FILE.parent.mkdir(parents=True, exist_ok=True)
    with BUDGET_FILE.open("w") as handle:
        json.dump(record, handle)
