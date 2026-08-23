"""The Python half of the cross-language catering parity gate.

``app/test/kuchnia_parity_test.dart`` asserts the *same* expectations against
the *same* ``tests/fixtures/kuchnia_day.json``.  Two independently written
suites from the same prose is not a gate -- one shared input with one shared
expected result is, because a divergence has to show up as a failure on one
side rather than as two self-consistent implementations.

What the parity actually protects, per ``docs/kuchnia-wikinga.md``:

* **Slot assignment.** A slot one device offers while the other does not is a
  checkpoint that can never be satisfied -- a permanent lock.
* **Which dishes are dropped.** If the two sides disagree, each re-adds what
  the other dropped, ``add_manual_entry`` restamps ``t`` unconditionally, and
  the curated bank republishes to every peer on every refresh.
* **Bank keys and record values.** Divergence there is the same flood by a
  different route.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from diet_guard._kuchnia_import import dish_to_record
from diet_guard._kuchnia_parse import Dish, parse_menu
from diet_guard._kuchnia_spread import assign_slots

FIXTURE = Path(__file__).resolve().parents[2] / "tests/fixtures/kuchnia_day.json"


@pytest.fixture(name="fixture")
def _fixture() -> dict[str, Any]:
    """The shared payload/expected pair, read from the committed JSON.

    Typed ``Any`` deliberately: this is decoded JSON whose nested shape is the
    fixture's own contract, and every read below is an assertion about that
    shape. Threading precise types through would restate the fixture's schema
    in the type system without making a divergence any more visible.
    """
    with FIXTURE.open(encoding="utf-8") as handle:
        data: dict[str, Any] = json.load(handle)
        return data


@pytest.fixture(name="dishes")
def _dishes(fixture: dict[str, Any]) -> list[Dish]:
    """The dishes the parser extracts from the shared payload."""
    return parse_menu(fixture["payload"])


def _slots_for(key: str) -> tuple[int, ...]:
    """Turn a fixture slot key such as ``"8,12,16,20"`` into slot hours."""
    return tuple(int(part) for part in key.split(","))


def test_fixture_is_present() -> None:
    """The fixture is shared with ``flutter test``; a move breaks both silently.

    Asserted explicitly so a relocation fails here with a clear reason rather
    than as a confusing KeyError inside another test.
    """
    assert FIXTURE.is_file(), f"shared parity fixture missing at {FIXTURE}"


def test_parsed_dishes_match_expected(
    fixture: dict[str, Any], dishes: list[Dish]
) -> None:
    """Every kept dish matches the shared expectation field for field."""
    expected = fixture["expected"]["dishes"]
    actual = [
        {
            "name": dish.name,
            "kcal": dish.kcal,
            "protein_g": dish.protein_g,
            "carbs_g": dish.carbs_g,
            "fat_g": dish.fat_g,
            "grams": dish.grams,
            "priority": dish.priority,
            "slot_label": dish.slot_label,
        }
        for dish in dishes
    ]
    assert actual == expected


def test_dropped_count_matches(fixture: dict[str, Any], dishes: list[Dish]) -> None:
    """The same meals are refused on both sides.

    A vacuous assertion against a clean capture, which is why the fixture
    carries a per-100 g mix-up, an absurd portion, a stringly-typed number, a
    non-dict entry and a meal with no nutrition at all.
    """
    total = len(fixture["payload"]["deliveryMenuMeal"])
    assert total - len(dishes) == fixture["expected"]["dropped_count"]
    assert fixture["expected"]["dropped_count"] > 0


def test_slot_assignment_matches(fixture: dict[str, Any], dishes: list[Dish]) -> None:
    """``i * S // N`` lands each dish on the slot the Dart side also picks."""
    for key, expected in fixture["expected"]["slots"].items():
        subject = dishes[:3] if key.startswith("first_three_") else dishes
        hours = _slots_for(key.removeprefix("first_three_"))
        actual = [item.slot for item in assign_slots(subject, hours)]
        assert actual == expected, f"slot assignment diverged for {key}"


def test_slot_order_matches(fixture: dict[str, Any], dishes: list[Dish]) -> None:
    """Ordering is total, so the twin-dish pair cannot reshuffle between runs.

    Python's ``sorted`` is stable and Dart's ``List.sort`` is not, so two
    dishes sharing both priority and name are the case that forces both
    comparators to be total.
    """
    ordered = assign_slots(dishes, (8, 12, 16, 20))
    assert [item.dish.name for item in ordered] == fixture["expected"]["slot_order"]


def test_bank_keys_match(fixture: dict[str, Any], dishes: list[Dish]) -> None:
    """Both devices key the curated bank identically for these dish names."""
    keys = [dish.name.strip().casefold() for dish in dishes]
    assert keys == fixture["expected"]["bank_keys"]


def test_bank_records_match(fixture: dict[str, Any], dishes: list[Dish]) -> None:
    """A banked record is value-identical to the one Dart would write."""
    records = [dish_to_record(dish) for dish in dishes]
    assert records == fixture["expected"]["bank_records"]


def test_bank_record_numbers_are_floats(dishes: list[Dish]) -> None:
    """Macros bank as floats, so Dart must ``.toDouble()`` before encoding.

    ``jsonEncode(435)`` emits ``435`` where Python emits ``435.0``. Left
    unpinned, an int-typed Dart macro produces a byte-different record for the
    same dish, every refresh sees a change, and the curated bank republishes to
    every peer -- the same flood a tolerance mismatch causes.
    """
    for record in (dish_to_record(dish) for dish in dishes):
        for key in ("kcal", "protein_g", "carbs_g", "fat_g", "grams"):
            assert isinstance(record[key], float), f"{key} must bank as a float"
        # ``count`` is the exception: an int on both sides.
        assert isinstance(record["count"], int)
        assert not isinstance(record["count"], bool)
