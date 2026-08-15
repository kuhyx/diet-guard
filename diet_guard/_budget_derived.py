"""Values derived from the stored budget record.

Split out of :mod:`._budget` to keep both files under the repo's 250-line
limit.  Nothing here opens a file: both helpers read through
:func:`diet_guard._budget._read_record`, so ``BUDGET_FILE`` stays named by
:mod:`._budget` alone -- which is what ``tests/conftest.py`` redirects, and
what ``test_state_redirect.py`` enforces.
"""

from __future__ import annotations

from diet_guard._budget import PROTEIN_G_PER_KG, BudgetError, _read_record

__all__ = ["budget_weight", "protein_target_g"]


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
