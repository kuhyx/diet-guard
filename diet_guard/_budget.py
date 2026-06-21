"""Hidden, tamper-hardened daily calorie budget for diet_guard.

This mirrors how ``phone_focus_mode`` hides the home GPS coordinates: the real
number never lives in committed source and is never printed.  It is computed
once from biometrics at ``init`` time, written to a runtime-only file in the
XDG data dir (git-ignored, exactly like the phone's ``config_secrets.sh``), and
locked with ``chattr +i`` so changing it costs a deliberate ``sudo`` step.

Honest threat model (the same one the phone accepts):

* The point is **friction in a weak moment**, not cryptographic secrecy.  The
  Mifflin-St Jeor formula is right here in source and you know your own weight,
  so a determined you can always recompute the number -- just as a determined
  you can root the phone and read the coordinates.
* The shared HMAC key at ``/etc/workout-locker/hmac.key`` is world-readable, so
  the signature defeats a *naive* edit (and detects disk corruption) but not
  someone who reads the key and re-signs.  The signature is tamper-*evidence*,
  not a tamper-*lock*.
* The real lock is ``chattr +i``: removing the immutable bit needs root, which
  is the actual speed bump.  The strongest layer of all is simply that the
  value is never displayed, so there is no on-screen anchor to fixate on.
"""

from __future__ import annotations

import base64
import binascii
from dataclasses import dataclass
import hmac
import json
import logging

from gatelock.log_integrity import compute_entry_hmac

from python_pkg.diet_guard._constants import BUDGET_FILE

_logger = logging.getLogger(__name__)

# Schema version stored inside the sealed blob, so a future format change can be
# detected rather than silently misread.  v2 adds the optional body weight (``w``)
# used to derive a protein target; v1 seals (budget only) still read correctly.
_SEAL_VERSION = 2

# A medically sane lower bound.  Even an aggressive deficit must not seal a
# starvation-level target, so the computed value is floored here.
_MIN_SANE_BUDGET = 1200

# Daily protein target for an active adult holding muscle on a deficit, in grams
# per kg of body weight.  Used only to show a target in the dashboard; it has no
# part in the sealed calorie budget maths.
PROTEIN_G_PER_KG = 1.8

# Probe payload used only to check whether the shared HMAC key can be loaded.
_KEY_PROBE: dict[str, object] = {"_probe": True}


class BudgetError(Exception):
    """Base class for all budget-access failures."""


class BudgetNotInitializedError(BudgetError):
    """Raised when no sealed budget exists yet (``init`` never run)."""

    def __init__(self) -> None:
        """Initialize with a fixed, side-effect-free message."""
        super().__init__("daily budget has not been initialized")


class BudgetSealBrokenError(BudgetError):
    """Raised when the sealed budget is unreadable, corrupt, or tampered."""

    def __init__(self) -> None:
        """Initialize with a fixed, side-effect-free message."""
        super().__init__("daily budget seal is broken (tampered or corrupted)")


class BudgetLockedError(BudgetError):
    """Raised when the budget file is immutable and cannot be rewritten."""

    def __init__(self) -> None:
        """Initialize with a fixed, side-effect-free message."""
        super().__init__("daily budget file is locked (chattr +i)")


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


def _hmac_key_available() -> bool:
    """Return True if the shared HMAC key can be loaded for signing."""
    return compute_entry_hmac(_KEY_PROBE) is not None


def is_initialized() -> bool:
    """Return True if a sealed budget file exists on disk."""
    return BUDGET_FILE.exists()


def lock_command() -> str:
    """Return the shell command that makes the sealed budget immutable."""
    return f"sudo chattr +i {BUDGET_FILE}"


def unlock_command() -> str:
    """Return the shell command that clears the immutable bit before re-init."""
    return f"sudo chattr -i {BUDGET_FILE}"


def seal_budget(value: int, *, weight_kg: float | None = None) -> None:
    """Write ``value`` to the runtime budget file, base64-wrapped and signed.

    The value is JSON-encoded, base64-wrapped (so a casual ``cat`` shows no
    recognizable number) and HMAC-signed (so a naive edit is detectable).  The
    file is *not* made immutable here -- that needs root; the caller prints
    :func:`lock_command` for the user (or install.sh) to run.

    Args:
        value: The computed daily budget in kcal.
        weight_kg: Body weight in kg to store alongside the budget, so a protein
            target can later be derived.  Optional; omitting it seals a
            budget-only blob that reads back with no protein target.

    Raises:
        BudgetLockedError: If the existing file is immutable (run
            :func:`unlock_command` first).
    """
    inner: dict[str, object] = {"v": _SEAL_VERSION, "b": int(value)}
    if weight_kg is not None:
        inner["w"] = round(float(weight_kg), 1)
    blob = json.dumps(inner, sort_keys=True, separators=(",", ":")).encode()
    record: dict[str, object] = {"data": base64.b64encode(blob).decode("ascii")}
    signature = compute_entry_hmac(inner)
    if signature is not None:
        record["hmac"] = signature
    else:
        _logger.warning("HMAC key unavailable - sealing budget unsigned")

    BUDGET_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        with BUDGET_FILE.open("w") as handle:
            json.dump(record, handle)
    except PermissionError as exc:
        raise BudgetLockedError from exc


def _decode_inner(record: object) -> dict[str, object]:
    """Return the inner payload dict from a parsed seal record.

    Raises:
        BudgetSealBrokenError: If the record shape or base64 is invalid.
    """
    if not isinstance(record, dict):
        raise BudgetSealBrokenError
    data = record.get("data")
    if not isinstance(data, str):
        raise BudgetSealBrokenError
    try:
        inner = json.loads(base64.b64decode(data, validate=True))
    except (binascii.Error, ValueError) as exc:
        raise BudgetSealBrokenError from exc
    if not isinstance(inner, dict):
        raise BudgetSealBrokenError
    return inner


def _verify_signature(record: dict[str, object], inner: dict[str, object]) -> None:
    """Check the seal's HMAC, mirroring the food log's degradation rules.

    A present signature must verify.  A missing signature is tolerated only on a
    system with no key at all; a stripped signature where a key *is* available
    means someone removed it to cheat.

    Raises:
        BudgetSealBrokenError: If the signature is missing-but-keyed, or wrong.
    """
    stored = record.get("hmac")
    if isinstance(stored, str):
        expected = compute_entry_hmac(inner)
        if expected is None or not hmac.compare_digest(stored, expected):
            raise BudgetSealBrokenError
        return
    if _hmac_key_available():
        raise BudgetSealBrokenError


def _load_verified_inner() -> dict[str, object]:
    """Read, decode, and integrity-check the sealed blob, returning its payload.

    Returns:
        The inner payload dict (carrying ``b`` and, for v2 seals, ``w``).

    Raises:
        BudgetNotInitializedError: If no budget has been sealed yet.
        BudgetSealBrokenError: If the file is corrupt, mis-typed, or tampered.
    """
    if not BUDGET_FILE.exists():
        raise BudgetNotInitializedError
    try:
        with BUDGET_FILE.open() as handle:
            record = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise BudgetSealBrokenError from exc
    inner = _decode_inner(record)
    # ``record`` is a dict here: _decode_inner rejects any non-dict already.
    _verify_signature(record, inner)
    return inner


def daily_budget() -> int:
    """Return the sealed daily budget, verifying integrity first.

    This is the only way callers obtain the number, and they must use it for an
    internal decision (over/under) without printing it.

    Returns:
        The daily kcal budget.

    Raises:
        BudgetNotInitializedError: If no budget has been sealed yet.
        BudgetSealBrokenError: If the file is corrupt, mis-typed, or tampered.
    """
    inner = _load_verified_inner()
    value = inner.get("b")
    if isinstance(value, bool) or not isinstance(value, int):
        raise BudgetSealBrokenError
    return value


def budget_weight() -> float | None:
    """Return the body weight stored with the budget, or None if unavailable.

    Returns:
        The stored weight in kg, or None for a pre-v2 (budget-only) seal.

    Raises:
        BudgetNotInitializedError: If no budget has been sealed yet.
        BudgetSealBrokenError: If the file is corrupt, mis-typed, or tampered.
    """
    inner = _load_verified_inner()
    value = inner.get("w")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def protein_target_g() -> float | None:
    """Return the daily protein target in grams, or None if it cannot be derived.

    Derived from the stored body weight at :data:`PROTEIN_G_PER_KG`.  Returns
    None -- rather than raising -- whenever the target is simply unavailable (no
    budget sealed, a pre-v2 seal without weight, or a broken seal), so the
    dashboard can show calories and quietly omit the protein line.

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
