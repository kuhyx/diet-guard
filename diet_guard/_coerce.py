"""Small value-coercion helpers for diet_guard."""

from __future__ import annotations


def as_float(value: object) -> float:
    """Coerce a stored field to ``float``, defaulting to 0.0.

    Booleans are rejected (they are an ``int`` subclass but never a real numeric
    measurement here) and any non-numeric value yields 0.0, so callers reading
    semi-structured log/bank data get a safe number without guarding each read.

    Args:
        value: A value read back from a JSON-ish store.

    Returns:
        The value as a float, or 0.0 when it is absent, a bool, or non-numeric.
    """
    if isinstance(value, bool):
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    return 0.0
