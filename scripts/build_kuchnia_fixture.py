#!/usr/bin/env python3
"""Regenerate the shared cross-language catering parity fixture.

The fixture (``tests/fixtures/kuchnia_day.json``) is read by *both*
``diet_guard/tests/test_kuchnia_parity.py`` and
``app/test/kuchnia_parity_test.dart``.  Two independently written suites from
the same prose is not a gate; one shared input with one shared expected result
is.

``expected`` is generated from the Python implementation, which is the
reference the Dart port must reproduce.  That means regenerating after a
behaviour change will happily bless the new behaviour -- so only run this when
the change is intended, and re-read the diff before committing it.

The five real dishes live in ``tests/fixtures/kuchnia_real_meals.json``: a
scrubbed capture of the live panel on 2026-08-22, where the fields the parser
reads are verbatim, opaque ids are replaced with synthetic ones, and
image/allergen/review metadata is dropped.  Every other meal is synthetic and
pins exactly one drop or fallback path.

Run it from the repo root, where the editable install puts ``diet_guard`` on
the path -- the same assumption the test suite makes. Both forms work:

    python3 scripts/build_kuchnia_fixture.py
    python3 -m scripts.build_kuchnia_fixture
"""

from __future__ import annotations

import json
from pathlib import Path

from diet_guard._kuchnia_import import dish_to_record
from diet_guard._kuchnia_parse import Dish, parse_menu
from diet_guard._kuchnia_spread import assign_slots

FIXTURE = Path(__file__).resolve().parent.parent / "tests/fixtures/kuchnia_day.json"

#: The real, scrubbed dishes, kept as a sidecar data file rather than a literal
#: here: transcribing them by hand silently corrupted three of the five (wrong
#: macros, truncated names) and the mistake was invisible in review.
#:
#: Diacritics are deliberately preserved. The two devices normalize bank keys
#: with different primitives (Python ``str.casefold()``, Dart
#: ``String.toLowerCase()``) and this is what pins their agreement across the
#: Polish alphabet.
REAL_MEALS_FILE = FIXTURE.parent / "kuchnia_real_meals.json"


def _real_meals() -> list[dict[str, object]]:
    """Load the scrubbed capture of the live panel on 2026-08-22."""
    with REAL_MEALS_FILE.open(encoding="utf-8") as handle:
        return json.load(handle)


def _nutrition(
    weight: float, kcal: object, protein: float, carbs: float, fat: float
) -> dict[str, object]:
    """Build a minimal ``nutrition`` block for a synthetic meal."""
    return {
        "weight": weight,
        "calories": kcal,
        "protein": protein,
        "carbohydrate": carbs,
        "fat": fat,
    }


#: One synthetic meal per parser branch. Without these, "dropped dishes" is a
#: vacuous assertion -- a real capture is all happy path.
_SYNTHETIC_MEALS: list[object] = [
    # Macros quoted per 100 g against a per-portion kcal: the one failure mode
    # that would silently skew every logged meal by a factor of several.
    {
        "mealName": "Obiad",
        "menuMealName": "Per-100g mix-up, dropped",
        "mealPriority": 6,
        "nutrition": _nutrition(400.0, 900.0, 5.0, 6.0, 2.0),
    },
    # Portion outside the sane gram band (kg mistaken for g).
    {
        "mealName": "Kolacja",
        "menuMealName": "Absurd portion, dropped",
        "mealPriority": 7,
        "nutrition": _nutrition(9000.0, 500.0, 30.0, 60.0, 15.0),
    },
    # No mealPriority -> falls back to 1-based payload position.
    {
        "mealName": "Przekąska",
        "menuMealName": "No priority, kept",
        "nutrition": _nutrition(120.0, 300.0, 10.0, 40.0, 8.0),
    },
    # A numeric field delivered as a JSON string. ``as_float`` rejects strings
    # (0.0), so the energy check fails and the dish drops. Pins the coercion
    # contract: Dart must NOT `double.tryParse` its way to a different answer.
    {
        "mealName": "Obiad",
        "menuMealName": "Stringly typed, dropped",
        "mealPriority": 8,
        "nutrition": _nutrition(200.0, "435", 25.0, 50.0, 12.0),
    },
    # Not a dict at all.
    "not-a-meal",
    # ``nutrition`` absent entirely.
    {
        "mealName": "Obiad",
        "menuMealName": "No nutrition, dropped",
        "mealPriority": 9,
    },
    # Two dishes sharing BOTH priority and name. Python's ``sorted`` is stable
    # and Dart's ``List.sort`` is not, so this pair is what forces both sides to
    # make the comparator total.
    {
        "mealName": "Obiad",
        "menuMealName": "Twin dish",
        "mealPriority": 5,
        "nutrition": _nutrition(300.0, 400.0, 25.0, 45.0, 12.0),
    },
    {
        "mealName": "Obiad",
        "menuMealName": "Twin dish",
        "mealPriority": 5,
        "nutrition": _nutrition(300.0, 400.0, 25.0, 45.0, 12.0),
    },
]


def _dish_json(dish: Dish) -> dict[str, object]:
    """Serialize a ``Dish`` field-for-field for the expected block."""
    return {
        "name": dish.name,
        "kcal": dish.kcal,
        "protein_g": dish.protein_g,
        "carbs_g": dish.carbs_g,
        "fat_g": dish.fat_g,
        "grams": dish.grams,
        "priority": dish.priority,
        "slot_label": dish.slot_label,
    }


def build() -> dict[str, object]:
    """Return the whole fixture: the payload and its expected results."""
    payload = {
        "deliveryMenuMeal": [*_real_meals(), *_SYNTHETIC_MEALS],
        "menuVisible": True,
        "showNutrition": True,
    }
    dishes = parse_menu(payload)
    default_slots = (8, 12, 16, 20)
    return {
        "_comment": (
            "Shared parity fixture for the Kuchnia Wikinga catering import. "
            "Read by BOTH diet_guard/tests/test_kuchnia_parity.py and "
            "app/test/kuchnia_parity_test.dart -- same input, same expected "
            "result. Regenerate with scripts/build_kuchnia_fixture.py."
        ),
        "payload": payload,
        "expected": {
            "dishes": [_dish_json(dish) for dish in dishes],
            "dropped_count": len(payload["deliveryMenuMeal"]) - len(dishes),
            "slots": {
                "8,12,16,20": [s.slot for s in assign_slots(dishes, default_slots)],
                "8,12,16,20,22": [
                    s.slot for s in assign_slots(dishes, (8, 12, 16, 20, 22))
                ],
                # The other direction: fewer dishes than slots.
                "first_three_8,12,16,20": [
                    s.slot for s in assign_slots(dishes[:3], default_slots)
                ],
            },
            "slot_order": [s.dish.name for s in assign_slots(dishes, default_slots)],
            "bank_keys": [dish.name.strip().casefold() for dish in dishes],
            "bank_records": [dish_to_record(dish) for dish in dishes],
        },
    }


def main() -> None:
    """Write the fixture to disk.

    Deliberately silent: ``T201`` bans ``print`` here, and the script's output
    is the file itself -- ``git diff`` is how you check what changed.
    """
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    with FIXTURE.open("w", encoding="utf-8") as handle:
        json.dump(build(), handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    main()
