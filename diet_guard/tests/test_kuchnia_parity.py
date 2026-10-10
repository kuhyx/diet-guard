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
* **Fill all with catering.** Which dishes ``fill_plan`` keeps and which
  ``log_dishes`` writes, so both devices fill the same empty slots.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest

from diet_guard import _kuchnia_log
from diet_guard._kuchnia_import import dish_to_record
from diet_guard._kuchnia_parse import Dish, parse_menu
from diet_guard._kuchnia_spread import SlottedDish, assign_slots

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
    """Turn a fixture slot key such as ``"480,720,960,1200"`` into slot minutes."""
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
        minutes = _slots_for(key.removeprefix("first_three_"))
        actual = [item.slot for item in assign_slots(subject, minutes)]
        assert actual == expected, f"slot assignment diverged for {key}"


def test_slot_order_matches(fixture: dict[str, Any], dishes: list[Dish]) -> None:
    """Ordering is total, so the twin-dish pair cannot reshuffle between runs.

    Python's ``sorted`` is stable and Dart's ``List.sort`` is not, so two
    dishes sharing both priority and name are the case that forces both
    comparators to be total.
    """
    ordered = assign_slots(dishes, (480, 720, 960, 1200))
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


def _spread(
    dishes: list[Dish], fill: dict[str, Any], case: dict[str, Any]
) -> list[SlottedDish]:
    """Re-spread the case's dish subset; never a slice of the full spread."""
    return assign_slots([dishes[i] for i in case["take"]], fill["slots"])


def test_fill_plan_matches(
    fixture: dict[str, Any], dishes: list[Dish], monkeypatch: pytest.MonkeyPatch
) -> None:
    """Only dishes whose slot is empty today are proposed, doubles included.

    Called through the module so a patched ``fill_plan`` is the one exercised.
    """
    fill = fixture["expected"]["fill"]
    assert fill["fill_plan"], "fixture carries no fill_plan cases"
    for key, case in fill["fill_plan"].items():
        today = [{"slot": slot} for slot in case["occupied"]]
        monkeypatch.setattr(_kuchnia_log, "today_entries", lambda t=today: t)
        kept = _kuchnia_log.fill_plan(_spread(dishes, fill, case))
        actual = [[item.dish.name, item.slot] for item in kept]
        assert actual == case["expected"], f"fill_plan diverged for {key}"


def test_log_dishes_matches(
    fixture: dict[str, Any], dishes: list[Dish], monkeypatch: pytest.MonkeyPatch
) -> None:
    """The same dishes are written, a twin pair in one slot landing once.

    ``log_meal`` is replaced by a recorder, so nothing reaches the log.
    """
    fill = fixture["expected"]["fill"]
    for key, case in fill["log_dishes"].items():
        recorder = MagicMock()
        monkeypatch.setattr(_kuchnia_log, "today_entries", lambda c=case: c["today"])
        monkeypatch.setattr(_kuchnia_log, "log_meal", recorder)
        _kuchnia_log.log_dishes(_spread(dishes, fill, case))
        written = [[call.args[0], call.args[2]] for call in recorder.call_args_list]
        assert written == case["expected"], f"log_dishes diverged for {key}"


def test_twin_case_is_not_vacuous(fixture: dict[str, Any], dishes: list[Dish]) -> None:
    """The intra-batch case really puts two identical dishes in one slot.

    Without this, a regenerated fixture whose spread separates the twins would
    keep passing while no longer testing the dedup at all.
    """
    fill = fixture["expected"]["fill"]
    case = fill["log_dishes"]["twins_share_16"]
    spread = [(item.dish.name, item.slot) for item in _spread(dishes, fill, case)]
    assert spread.count(("Twin dish", 960)) == 2
    assert case["expected"].count(["Twin dish", 960]) == 1
