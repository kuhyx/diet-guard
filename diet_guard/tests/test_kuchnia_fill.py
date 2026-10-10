"""Tests for "fill all with catering": which slots a delivery may fill.

The rule is shared by ``diet-guard kuchnia --log`` and the gate's "Fill all"
button (:func:`diet_guard._kuchnia_log.fill_plan`): every slot today, but only
the ones with nothing logged yet.  A slot the user already ate something in
keeps that meal rather than gaining a catering dish on top.
"""

from __future__ import annotations

from dataclasses import replace
from unittest.mock import patch

from diet_guard import _cli_kuchnia
from diet_guard._estimator import Nutrition
from diet_guard._kuchnia_log import fill_plan, log_dishes
from diet_guard._kuchnia_parse import Dish
from diet_guard._kuchnia_spread import SlottedDish
from diet_guard._state import log_meal
from diet_guard._state_today import today_entries


def _slotted(name: str, slot: int) -> SlottedDish:
    dish = Dish(
        name=name,
        kcal=400.0,
        protein_g=30.0,
        carbs_g=40.0,
        fat_g=12.0,
        grams=300.0,
        priority=1,
        slot_label="Obiad",
    )
    return SlottedDish(dish, slot)


def _eat(desc: str, slot: int) -> None:
    log_meal(desc, Nutrition(95.0, 0.5, 25.0, 0.3, 180.0, "manual"), slot)


class TestFillPlan:
    def test_an_empty_day_fills_every_slot(self) -> None:
        plan = [_slotted("A", 480), _slotted("B", 720), _slotted("C", 1200)]
        assert fill_plan(plan) == plan

    def test_a_slot_with_a_meal_keeps_it(self) -> None:
        _eat("apple", 720)
        plan = fill_plan([_slotted("A", 480), _slotted("B", 720), _slotted("C", 1200)])
        assert [item.slot for item in plan] == [480, 1200]

    def test_two_dishes_sharing_an_empty_slot_both_land(self) -> None:
        # 5 dishes on 4 slots double up the first; occupancy is read once,
        # before the batch, so the second dish is not refused by the first.
        plan = fill_plan([_slotted("A", 480), _slotted("B", 480)])
        assert log_dishes(plan) == ["A", "B"]

    def test_a_full_day_fills_nothing(self) -> None:
        for slot in (480, 720):
            _eat("apple", slot)
        assert fill_plan([_slotted("A", 480), _slotted("B", 720)]) == []

    def test_a_meal_near_a_slot_occupies_it(self) -> None:
        # Logged at 08:15 (say, under an older schedule): it snaps to 08:00,
        # the same rule the gate uses, so catering must not double that slot.
        _eat("apple", 495)
        plan = fill_plan([_slotted("A", 480), _slotted("B", 720)])
        assert [item.slot for item in plan] == [720]


class TestCliFill:
    def test_log_skips_a_taken_slot(self) -> None:
        # Two dishes on the default four slots spread to 08:00 and 16:00.
        _eat("apple", 480)
        dishes = [
            replace(_slotted("Owsianka", 480).dish, priority=1),
            replace(_slotted("Kaszotto", 960).dish, priority=2),
        ]
        lines: list[str] = []
        with patch.object(
            _cli_kuchnia, "refresh_delivery", return_value=(dishes, None)
        ):
            _cli_kuchnia.cmd_kuchnia(lines.append, lambda _p: "y", log=True, yes=False)
        logged = {(entry["desc"], entry["slot"]) for entry in today_entries()}
        assert logged == {("apple", 8), ("Kaszotto", 16)}
        assert "logged 1 meal(s)." in lines
