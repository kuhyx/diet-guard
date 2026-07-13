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
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import json
import logging

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
    return datetime.now(tz=timezone.utc).astimezone()


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


@dataclass(frozen=True)
class Biometrics:
    """Body metrics that feed the Mifflin-St Jeor budget formula.

    Grouped into one value object so the budget calculation stays under the
    repo's five-argument lint ceiling and so the inputs travel together.

    Attributes:
        weight_kg: Body mass in kilograms.
        height_cm: Height in centimetres.
        age_years: Age in years.
        is_male: True for the male BMR constant (+5), False for female (-161).
    """

    weight_kg: float
    height_cm: float
    age_years: float
    is_male: bool


def mifflin_st_jeor_bmr(bio: Biometrics) -> float:
    """Return resting metabolic rate via the Mifflin-St Jeor equation.

    Args:
        bio: The person's body metrics.

    Returns:
        Basal metabolic rate in kcal/day.
    """
    base = 10.0 * bio.weight_kg + 6.25 * bio.height_cm - 5.0 * bio.age_years
    return base + 5.0 if bio.is_male else base - 161.0


def compute_target_budget(
    bio: Biometrics,
    *,
    activity_factor: float,
    deficit_kcal: float,
) -> int:
    """Return the daily kcal target: TDEE minus a deficit, floored for safety.

    TDEE (total daily energy expenditure) is the BMR scaled by an activity
    factor; subtracting a deficit yields a target that drives gradual loss.

    Args:
        bio: The person's body metrics.
        activity_factor: Multiplier for daily activity (e.g. 1.2 sedentary,
            1.375 light, 1.55 moderate, 1.725 very active).
        deficit_kcal: Calories subtracted from TDEE for weight loss.

    Returns:
        The target budget in kcal, never below ``_MIN_SANE_BUDGET``.
    """
    bmr = mifflin_st_jeor_bmr(bio)
    tdee = bmr * activity_factor
    target = round(tdee - deficit_kcal)
    return max(target, _MIN_SANE_BUDGET)


def is_initialized() -> bool:
    """Return True if a budget file exists on disk."""
    return BUDGET_FILE.exists()


def write_budget(value: int, *, weight_kg: float | None = None) -> None:
    """Write ``value`` as the daily kcal budget, plainly (no seal, no signing).

    Stamps a ``t`` edit timestamp on every write (unlike a food-log entry,
    the budget can be edited repeatedly, so :mod:`diet_guard._sync` needs to
    know *when* this write happened to resolve a last-edit-wins merge
    against another device's write).

    Args:
        value: The daily budget in kcal.
        weight_kg: Body weight in kg to store alongside the budget, so a
            protein target can later be derived. Optional; omitting it
            writes a budget-only record that reads back with no protein
            target.
    """
    record: dict[str, object] = {
        "v": _FILE_VERSION,
        "b": int(value),
        "t": _now_local().isoformat(timespec="seconds"),
    }
    if weight_kg is not None:
        record["w"] = round(float(weight_kg), 1)
    write_raw_record(record)


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


def budget_weight() -> float | None:
    """Return the body weight stored with the budget, or None if unavailable.

    Returns:
        The stored weight in kg, or None for a pre-v2 (budget-only) record.

    Raises:
        BudgetNotInitializedError: If no budget has been set yet.
        BudgetFileCorruptError: If the file exists but cannot be parsed.
    """
    record = _read_record()
    value = record.get("w")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def protein_target_g() -> float | None:
    """Return the daily protein target in grams, or None if it cannot be derived.

    Derived from the stored body weight at :data:`PROTEIN_G_PER_KG`.  Returns
    None -- rather than raising -- whenever the target is simply unavailable
    (no budget set, a pre-v2 record without weight, or a corrupt file), so
    the dashboard can show calories and quietly omit the protein line.

    Returns:
        The protein target in grams, or None when weight is unknown.
    """
    try:
        weight = budget_weight()
    except BudgetError:
        return None
    if weight is None:
        return None
    return round(weight * PROTEIN_G_PER_KG, 1)


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
    except (OSError, json.JSONDecodeError):
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
