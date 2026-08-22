"""Tests for the catering menu parser and its slot assignment.

The unit check in :mod:`diet_guard._kuchnia_parse` is the reason this file
matters most: the panel could quote macros per portion or per 100 g, and the
difference is invisible in a payload but skews every logged meal by a factor of
several. Both directions of that mix-up are asserted below.

The fixture is a trimmed copy of a real capture (2026-08-22), so the field
names and value shapes are the ones the live panel actually sends.
"""

from __future__ import annotations

from typing import cast

import pytest

from diet_guard._kuchnia_parse import Dish, parse_menu
from diet_guard._kuchnia_spread import assign_slots

# One real meal from the captured payload, macros per portion.
_REAL_MEAL: dict[str, object] = {
    "menuMealName": "Marchewkowe pancakes, twarożek cynamonowy, sos truskawkowy",
    "mealName": "Śniadanie",
    "mealPriority": 1,
    "nutrition": {
        "weight": 270.0,
        "calories": 435.0,
        "protein": 25.86,
        "carbohydrate": 54.64,
        "fat": 12.01,
        "dietaryFiber": 2.03,
    },
}


def _payload(
    nutrition: dict[str, object] | None = None,
    **overrides: object,
) -> dict[str, object]:
    """Return a one-meal payload with ``nutrition`` and top-level overrides."""
    meal = dict(_REAL_MEAL)
    nutrients = dict(cast("dict[str, object]", _REAL_MEAL["nutrition"]))
    nutrients.update(nutrition or {})
    meal["nutrition"] = nutrients
    meal.update(overrides)
    return {"deliveryMenuMeal": [meal]}


class TestParseMenu:
    def test_reads_a_real_meal(self) -> None:
        (dish,) = parse_menu(_payload())
        assert dish.name.startswith("Marchewkowe pancakes")
        assert dish.kcal == 435.0
        assert dish.grams == 270.0
        assert dish.protein_g == 25.86
        assert dish.priority == 1
        assert dish.slot_label == "Śniadanie"

    def test_uses_the_dish_name_not_the_slot_label(self) -> None:
        # ``mealName`` is "Śniadanie" for every breakfast ever delivered;
        # banking under it would collapse the whole diet into five entries.
        (dish,) = parse_menu(_payload())
        assert dish.name != "Śniadanie"

    def test_rejects_calories_quoted_per_100g(self) -> None:
        # 435 kcal for 270 g is 161 per 100 g. If the panel ever quotes it that
        # way, the macros no longer account for the energy and the dish must be
        # dropped rather than imported at a third of its real value.
        assert parse_menu(_payload(nutrition={"calories": 161.0})) == []

    def test_rejects_macros_quoted_per_100g(self) -> None:
        # The mirror image: calories per portion, macros per 100 g.
        assert (
            parse_menu(
                _payload(
                    nutrition={"protein": 9.6, "carbohydrate": 20.2, "fat": 4.4},
                ),
            )
            == []
        )

    @pytest.mark.parametrize("grams", [0.0, 0.27, 6000.0])
    def test_rejects_an_implausible_portion(self, grams: float) -> None:
        assert parse_menu(_payload(nutrition={"weight": grams})) == []

    def test_rejects_zero_calories(self) -> None:
        assert parse_menu(_payload(nutrition={"calories": 0.0})) == []

    def test_rejects_a_nameless_dish(self) -> None:
        assert parse_menu(_payload(menuMealName="   ")) == []

    def test_rejects_a_meal_with_no_nutrition_block(self) -> None:
        assert parse_menu({"deliveryMenuMeal": [{"menuMealName": "X"}]}) == []

    @pytest.mark.parametrize(
        "payload",
        ["nope", {}, {"deliveryMenuMeal": "x"}, {"deliveryMenuMeal": [None]}, 7],
    )
    def test_survives_junk(self, payload: object) -> None:
        assert parse_menu(payload) == []

    def test_one_bad_dish_does_not_cost_the_others(self) -> None:
        payload = {"deliveryMenuMeal": [_REAL_MEAL, {"bad": 1}]}
        assert len(parse_menu(payload)) == 1

    def test_a_boolean_priority_falls_back_to_position(self) -> None:
        # bool is an int subclass; True must not become priority 1 by accident.
        (dish,) = parse_menu(_payload(mealPriority=True))
        assert dish.priority == 1
        assert not isinstance(dish.priority, bool)

    def test_a_missing_priority_falls_back_to_position(self) -> None:
        meal = {k: v for k, v in _REAL_MEAL.items() if k != "mealPriority"}
        (dish,) = parse_menu({"deliveryMenuMeal": [meal]})
        assert dish.priority == 1

    def test_a_missing_slot_label_is_empty_not_absent(self) -> None:
        meal = {k: v for k, v in _REAL_MEAL.items() if k != "mealName"}
        (dish,) = parse_menu({"deliveryMenuMeal": [meal]})
        assert dish.slot_label == ""


def _dish(priority: int, name: str = "d") -> Dish:
    return Dish(
        name=f"{name}{priority}",
        kcal=100.0,
        protein_g=1.0,
        carbs_g=2.0,
        fat_g=3.0,
        grams=50.0,
        priority=priority,
        slot_label="",
    )


class TestAssignSlots:
    def test_follows_the_providers_priority_not_payload_order(self) -> None:
        dishes = [_dish(3), _dish(1), _dish(2)]
        assigned = assign_slots(dishes, (8, 12, 16))
        assert [item.dish.name for item in assigned] == ["d1", "d2", "d3"]
        assert [item.slot for item in assigned] == [8, 12, 16]

    def test_five_dishes_over_four_slots_double_up_the_earliest(self) -> None:
        assigned = assign_slots([_dish(i) for i in range(1, 6)], (8, 12, 16, 20))
        assert [item.slot for item in assigned] == [8, 8, 12, 16, 20]

    def test_five_dishes_over_five_slots_map_one_to_one(self) -> None:
        # kuhy's real schedule; the catering plan is also five meals.
        assigned = assign_slots([_dish(i) for i in range(1, 6)], (8, 11, 14, 17, 20))
        assert [item.slot for item in assigned] == [8, 11, 14, 17, 20]

    @pytest.mark.parametrize("count", range(1, 9))
    @pytest.mark.parametrize("span", range(2, 7))
    def test_assignment_is_monotonic_and_in_range(self, count: int, span: int) -> None:
        slots = tuple(range(8, 8 + span))
        assigned = assign_slots([_dish(i) for i in range(1, count + 1)], slots)
        got = [item.slot for item in assigned]
        assert len(got) == count
        assert got == sorted(got), "a later meal must never precede an earlier one"
        assert set(got) <= set(slots)
        assert got[0] == slots[0], "the first meal always starts the day"
        if count >= span:
            # Only a full (or over-full) day reaches the last slot. With fewer
            # dishes than slots the delivery genuinely ends earlier -- three
            # meals should not be stretched across breakfast-to-supper.
            assert got[-1] == slots[-1]

    def test_ties_break_deterministically(self) -> None:
        # Two dishes sharing a priority must not reshuffle between runs: an
        # unstable order looks like a change and re-stamps every bank record.
        dishes = [_dish(1, "b"), _dish(1, "a")]
        first = [item.dish.name for item in assign_slots(dishes, (8, 12))]
        second = [item.dish.name for item in assign_slots(dishes[::-1], (8, 12))]
        assert first == second

    @pytest.mark.parametrize(
        ("dishes", "slots"),
        [([], (8, 12)), ([_dish(1)], ())],
    )
    def test_nothing_to_assign_is_not_an_error(
        self,
        dishes: list[Dish],
        slots: tuple[int, ...],
    ) -> None:
        assert assign_slots(dishes, slots) == []
