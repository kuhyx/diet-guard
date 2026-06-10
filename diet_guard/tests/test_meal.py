"""Tests for _meal.py — composite-meal summing."""

from __future__ import annotations

from python_pkg.diet_guard._estimator import Nutrition
from python_pkg.diet_guard._meal import MEAL_SOURCE, MealItem, meal_total


def _item(
    name: str,
    kcal: float,
    macros: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0),
) -> MealItem:
    """Build a MealItem from a name, calories, and a (protein, carbs, fat, grams)."""
    protein, carbs, fat, grams = macros
    return MealItem(
        name,
        Nutrition(
            kcal=kcal,
            protein_g=protein,
            carbs_g=carbs,
            fat_g=fat,
            grams=grams,
            source="manual",
        ),
    )


class TestMealTotal:
    """Summing a meal's items."""

    def test_sums_every_field(self) -> None:
        """Each macro, calories, and weight are added across the items."""
        items = [
            _item("salad", 80, (2, 8, 5, 120)),
            _item("chicken", 330, (62, 0, 7, 200)),
            _item("rice", 260, (5, 56, 1, 180)),
        ]
        total = meal_total(items)
        assert total.kcal == 670
        assert total.protein_g == 69
        assert total.carbs_g == 64
        assert total.fat_g == 13
        assert total.grams == 500
        assert total.source == MEAL_SOURCE

    def test_empty_is_zero(self) -> None:
        """An empty meal sums to an all-zero composite rather than raising."""
        assert meal_total([]) == Nutrition(
            kcal=0.0,
            protein_g=0.0,
            carbs_g=0.0,
            fat_g=0.0,
            grams=0.0,
            source=MEAL_SOURCE,
        )

    def test_rounds_to_one_decimal(self) -> None:
        """Floating sums are rounded to 0.1, like the rest of the log."""
        assert meal_total([_item("a", 0.1), _item("b", 0.2)]).kcal == 0.3
