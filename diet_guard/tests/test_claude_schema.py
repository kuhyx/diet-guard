"""The estimator's output schema: only a sane, complete JSON object passes."""

from __future__ import annotations

import math
from typing import Any

import pytest

from diet_guard._claude_schema import (
    SCHEMA,
    Estimate,
    InvalidEstimateError,
    parse_estimate,
)

GOOD: dict[str, Any] = {
    "desc": "2 jajka sadzone, kromka chleba",
    "grams": 190,
    "kcal": 410,
    "protein_g": 17.5,
    "carbs_g": 22,
    "fat_g": 26,
}


def test_valid_object_becomes_an_estimate() -> None:
    """Every required number is carried over, no components by default."""
    est = parse_estimate(GOOD)
    assert est == Estimate(
        desc="2 jajka sadzone, kromka chleba",
        grams=190.0,
        kcal=410.0,
        protein_g=17.5,
        carbs_g=22.0,
        fat_g=26.0,
        components=None,
    )


def test_components_are_validated_and_kept() -> None:
    """A component carries the same five numbers plus its name."""
    item = {"name": "jajko", "grams": 60, "kcal": 90, "protein_g": 6, "carbs_g": 0.5}
    est = parse_estimate({**GOOD, "components": [{**item, "fat_g": 7}]})
    assert est.components is not None
    assert est.components[0]["name"] == "jajko"
    assert est.components[0]["fat_g"] == 7.0


@pytest.mark.parametrize(
    "bad",
    [
        {k: v for k, v in GOOD.items() if k != "kcal"},
        {**GOOD, "desc": "  "},
        {**GOOD, "desc": "x" * 121},
        {**GOOD, "desc": 5},
        {**GOOD, "grams": 0},
        {**GOOD, "grams": 6000},
        {**GOOD, "kcal": -1},
        {**GOOD, "kcal": 5001},
        {**GOOD, "protein_g": math.nan},
        {**GOOD, "fat_g": math.inf},
        {**GOOD, "carbs_g": "22"},
        {**GOOD, "kcal": True},
        {**GOOD, "components": "none"},
        {**GOOD, "components": [{"name": "x"}]},
        {
            **GOOD,
            "components": [
                {
                    "name": "",
                    "grams": 1,
                    "kcal": 1,
                    "protein_g": 0,
                    "carbs_g": 0,
                    "fat_g": 0,
                }
            ],
        },
        {**GOOD, "components": ["x"]},
    ],
)
def test_invalid_object_is_refused(bad: dict[str, Any]) -> None:
    """Missing, mistyped, non-finite or absurd values are never logged."""
    with pytest.raises(InvalidEstimateError):
        parse_estimate(bad)


def test_non_object_is_refused() -> None:
    """A list or string is not an estimate."""
    with pytest.raises(InvalidEstimateError):
        parse_estimate([GOOD])


def test_schema_requires_exactly_the_contract_fields() -> None:
    """The JSON schema handed to the model names every required field."""
    assert set(SCHEMA["required"]) == {
        "desc",
        "grams",
        "kcal",
        "protein_g",
        "carbs_g",
        "fat_g",
    }
    assert SCHEMA["additionalProperties"] is False
