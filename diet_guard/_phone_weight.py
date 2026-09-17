"""Carry the phone's morning weigh-in into the budget's stored weight.

The wake-alarm phone app ends every morning session with a typed weight,
published as ``latest_weight_kg`` on its synced record; ``wake_alarm._weight``
reads it on the PC. That weight is what the protein target here is derived
from (``_budget_derived.protein_target_g``), so after each successful
``sync`` the stored ``w`` is refreshed from it.

Only ``w`` moves. The kcal budget is not recomputed -- biometrics are
discarded by design on this side (see ``_budget_biometrics``), so there is
nothing to recompute it *from*. ``t`` is refreshed with ``w`` because both
ride the same edit timestamp into the per-field last-write-wins merge
(``sync_merge._budget``); a new weight under an old ``t`` would lose to
every other device on the next merge.

``wake_alarm`` is an optional neighbour, imported lazily: a machine without
it (or with a broken install) syncs exactly as before and simply never
refreshes the weight.
"""

from __future__ import annotations

from importlib import import_module
from typing import TYPE_CHECKING

from diet_guard._budget import _now_local, read_raw_record, write_raw_record

if TYPE_CHECKING:
    from collections.abc import Callable

__all__ = ["refresh_weight_from_phone", "update_weight"]

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


def refresh_weight_from_phone(emit: Callable[[str], None]) -> None:
    """Apply the phone's newest weigh-in to the stored weight, if it is newer.

    Skipped, silently, when: ``wake_alarm`` is not installed; nothing has
    been published (or the backend is unreadable -- ``latest_weight`` never
    raises); no budget exists; the weigh-in is not from a *later* day than
    the budget's last edit; or it matches the stored weight within
    :data:`_SAME_WEIGHT_KG`.

    The day comparison is strict. A weigh-in happens in the morning and a
    manual budget edit at any time of day, and ``t`` carries only the day's
    granularity worth trusting here, so on a shared day the budget edit is
    taken as the more recent human action and kept. The cost is one day of
    lag in that one case; the alternative overwrites an edit made hours
    after the weigh-in.

    Args:
        emit: One-line output sink, given a line only when a write happened.
    """
    try:
        weight_module = import_module("wake_alarm._weight")
    except ImportError:
        return
    weight = weight_module.latest_weight()
    if weight is None:
        return
    record = read_raw_record()
    if record is None:
        return
    if weight.date <= _budget_edit_day(record):
        return
    stored = record.get("w")
    if (
        isinstance(stored, (int, float))
        and not isinstance(stored, bool)
        and abs(float(stored) - weight.kg) < _SAME_WEIGHT_KG
    ):
        return
    update_weight(weight.kg)
    emit(f"weight: {weight.kg} kg from the phone ({weight.date}).")
