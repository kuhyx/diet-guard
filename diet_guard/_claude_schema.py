"""The estimator's strict output: a JSON schema and a validator.

The schema goes to the model as ``output_format`` (so the CLI constrains the
answer), and :func:`parse_estimate` re-validates what came back: a model
answer that is not a sane, complete object is never logged. Pure stdlib, so
the gate can import it.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Any, Final

MAX_DESC: Final = 120
MAX_GRAMS: Final = 5000.0
MAX_KCAL: Final = 5000.0

_NUMBERS: Final = ("grams", "kcal", "protein_g", "carbs_g", "fat_g")
_NUMBER: Final = {"type": "number", "minimum": 0}
_ITEM_PROPS: Final = {
    "name": {"type": "string", "minLength": 1, "maxLength": MAX_DESC},
    **dict.fromkeys(_NUMBERS, _NUMBER),
}

#: The JSON schema the model's answer must satisfy.
SCHEMA: Final[dict[str, Any]] = {
    "type": "object",
    "additionalProperties": False,
    "required": ["desc", *_NUMBERS],
    "properties": {
        "desc": {"type": "string", "minLength": 1, "maxLength": MAX_DESC},
        **dict.fromkeys(_NUMBERS, _NUMBER),
        "components": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["name", *_NUMBERS],
                "properties": _ITEM_PROPS,
            },
        },
    },
}


class InvalidEstimateError(ValueError):
    """The model's answer is not a usable estimate."""


@dataclass(frozen=True)
class Estimate:
    """One estimated meal: totals for the whole portion.

    Attributes:
        desc: Short name for the whole meal.
        grams: Total edible weight, greater than 0.
        kcal: Energy for the portion.
        protein_g: Protein for the portion.
        carbs_g: Carbohydrate for the portion.
        fat_g: Fat for the portion.
        components: Per-item breakdown, or None for a single item.
    """

    desc: str
    grams: float
    kcal: float
    protein_g: float
    carbs_g: float
    fat_g: float
    components: tuple[dict[str, object], ...] | None = None


def _number(data: dict[str, Any], key: str, ceiling: float) -> float:
    """``data[key]`` as a finite float in ``[0, ceiling]`` (bool is refused)."""
    value = data.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        msg = f"{key} is not a number"
        raise InvalidEstimateError(msg)
    number = float(value)
    if not math.isfinite(number) or not 0 <= number <= ceiling:
        msg = f"{key}={value!r} is out of range"
        raise InvalidEstimateError(msg)
    return number


def _text(data: dict[str, Any], key: str) -> str:
    """``data[key]`` as a non-blank string of at most :data:`MAX_DESC`."""
    value = data.get(key)
    if not isinstance(value, str) or not value.strip() or len(value) > MAX_DESC:
        msg = f"{key} is not a short non-blank string"
        raise InvalidEstimateError(msg)
    return value.strip()


def _macros(data: dict[str, Any]) -> dict[str, float]:
    """The five numbers every meal and every component carries."""
    numbers = {
        "grams": _number(data, "grams", MAX_GRAMS),
        "kcal": _number(data, "kcal", MAX_KCAL),
    }
    for key in ("protein_g", "carbs_g", "fat_g"):
        numbers[key] = _number(data, key, MAX_GRAMS)
    return numbers


def _component(item: object) -> dict[str, object]:
    """One validated component."""
    if not isinstance(item, dict):
        msg = "a component is not an object"
        raise InvalidEstimateError(msg)
    return {"name": _text(item, "name"), **_macros(item)}


def parse_estimate(data: object) -> Estimate:
    """Validate the model's answer.

    Raises:
        InvalidEstimateError: not an object, a field is missing or mistyped,
            a number is non-finite, negative or absurd, or ``grams`` is 0.
    """
    if not isinstance(data, dict):
        msg = "the answer is not an object"
        raise InvalidEstimateError(msg)
    numbers = _macros(data)
    if numbers["grams"] <= 0:
        msg = "grams must be greater than 0"
        raise InvalidEstimateError(msg)
    raw = data.get("components")
    components: tuple[dict[str, object], ...] | None = None
    if raw is not None:
        if not isinstance(raw, list):
            msg = "components is not a list"
            raise InvalidEstimateError(msg)
        components = tuple(_component(item) for item in raw)
    return Estimate(desc=_text(data, "desc"), components=components, **numbers)
