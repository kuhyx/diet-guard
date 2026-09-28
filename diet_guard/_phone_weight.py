"""Carry the newest logged weight into the budget's stored weight.

The Body weight log (:mod:`diet_guard._body_store`) holds every weigh-in --
the phone's morning ones, ingested each tick by :mod:`diet_guard._sync_body`,
and any typed on either device. Its newest entry is what the protein target
here is derived from (``_budget_derived.protein_target_g``), so after each
successful ``sync`` the stored ``w`` is refreshed from it.

Only ``w`` moves. The kcal budget is never recomputed -- the Body tab's
calorie table is informational, and the budget stays the number the user
edits. ``t`` is refreshed with ``w`` because both ride the same edit
timestamp into the per-field last-write-wins merge (``sync_merge._budget``);
a new weight under an old ``t`` would lose to every other device on the next
merge.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from diet_guard._body_store import newest_weight
from diet_guard._budget import _now_local, read_raw_record, write_raw_record

if TYPE_CHECKING:
    from collections.abc import Callable

__all__ = ["refresh_weight_from_log", "update_weight"]

# Below this the scale and the record agree; a rewrite would only churn ``t``.
_SAME_WEIGHT_KG = 0.05


def update_weight(kg: float) -> bool:
    """Set the budget record's stored weight to ``kg``; False when no budget.

    Writes through the raw accessors rather than :func:`_budget.write_budget`
    on purpose: that path stamps a budget change into the effective-from
    history, and the budget has not changed.
    """
    record = read_raw_record()
    if record is None:
        return False
    record["w"] = round(float(kg), 1)
    record["t"] = _now_local().isoformat(timespec="seconds")
    write_raw_record(record)
    return True


def _budget_edit_day(record: dict[str, object]) -> str:
    """The local ``yyyy-mm-dd`` of the record's last edit, or '' when unknown."""
    return str(record.get("t", ""))[:10]


def refresh_weight_from_log(emit: Callable[[str], None]) -> None:
    """Apply the weight log's newest weigh-in to the stored weight, if newer.

    Skipped, silently, when: the log is empty; no budget exists; the
    weigh-in is not from a *later* day than the budget's last edit; or it
    matches the stored weight within :data:`_SAME_WEIGHT_KG`.

    The day comparison is strict. A weigh-in happens in the morning and a
    manual budget edit at any time of day, and ``t`` carries only the day's
    granularity worth trusting here, so on a shared day the budget edit is
    taken as the more recent human action and kept. The cost is one day of
    lag in that one case; the alternative overwrites an edit made hours
    after the weigh-in.

    Args:
        emit: One-line output sink, given a line only when a write happened.
    """
    newest = newest_weight()
    if newest is None:
        return
    day, kg = newest
    record = read_raw_record()
    if record is None:
        return
    if day <= _budget_edit_day(record):
        return
    stored = record.get("w")
    if (
        isinstance(stored, (int, float))
        and not isinstance(stored, bool)
        and abs(float(stored) - kg) < _SAME_WEIGHT_KG
    ):
        return
    update_weight(kg)
    emit(f"weight: {kg} kg from the weight log ({day}).")
