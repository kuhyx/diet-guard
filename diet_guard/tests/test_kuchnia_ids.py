"""The auto-log entry id: one formula, pinned by the phone's shared fixture."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from diet_guard._kuchnia_ids import autolog_id, dish_key
from diet_guard._kuchnia_parse import parse_menu

FIXTURE = (
    Path(__file__).resolve().parents[2] / "tests/fixtures/kuchnia_autolog_ids.json"
)
_CASES = json.loads(FIXTURE.read_text(encoding="utf-8"))["cases"]


@pytest.mark.parametrize("case", _CASES, ids=lambda c: c["name_string"])
def test_ids_match_the_shared_fixture(case: dict[str, object]) -> None:
    """Key and id equal what the Dart port derives from the same input."""
    key = dish_key(case["delivery_meal_id"], str(case["name"]))
    assert key == case["dish_key"]
    assert autolog_id(str(case["delivery_date"]), key) == case["expected_id"]


def test_parser_carries_the_panel_meal_id() -> None:
    """``Dish.dish_key`` comes from ``deliveryMealId``, else the name."""
    meal = {
        "menuMealName": "Zupa",
        "mealPriority": 1,
        "nutrition": {
            "calories": 200.0,
            "protein": 10.0,
            "carbohydrate": 25.0,
            "fat": 6.0,
            "weight": 300.0,
        },
    }
    with_id, without = (
        parse_menu({"deliveryMenuMeal": [{**meal, **extra}]})[0]
        for extra in ({"deliveryMealId": 42}, {})
    )
    assert with_id.dish_key == "42"
    assert without.dish_key == "zupa"
