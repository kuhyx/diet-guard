#!/usr/bin/env python3
"""Regenerate the shared catering auto-log id fixture.

The fixture (``tests/fixtures/kuchnia_autolog_ids.json``) pins the entry id the
phone gives a catering dish it logs by itself. Each id is a UUID v5 over the
RFC 4122 URL namespace (``6ba7b811-9dad-11d1-80b4-00c04fd430c8``) of the string
``kuchnia:<deliveryDate YYYY-MM-DD>:<dishKey>``, so a repeat open and every
other device derive the same id and the merge collapses them to one entry.

``dishKey`` is the panel's ``deliveryMealId`` as a string (an int, or a
stripped string). Anything else, or a blank one, falls back to the dish's bank
key (name, stripped, lower-cased). The fallback cases use ASCII names only,
because ``str.casefold`` and Dart's ``toLowerCase`` agree there and diverge on
a few exotic characters.

The expected ids come from Python's stdlib ``uuid.uuid5`` on purpose: the Dart
test must reproduce a value it did not compute itself.

Run from the repo root:

    python3 scripts/build_kuchnia_autolog_fixture.py
"""

from __future__ import annotations

import json
from pathlib import Path
import uuid

FIXTURE = (
    Path(__file__).resolve().parent.parent / "tests/fixtures/kuchnia_autolog_ids.json"
)

#: (delivery date, raw ``deliveryMealId`` or None, dish name)
_CASES: list[tuple[str, object, str]] = [
    ("2026-11-17", 1001, "Marchewkowe pancakes"),
    ("2026-11-17", 1002, "Hummus paprykowy"),
    ("2026-11-18", 1001, "Marchewkowe pancakes"),
    ("2026-11-17", "A-77", "String id dish"),
    ("2026-11-17", " A-77 ", "Padded id dish"),
    ("2026-11-17", True, "Bool id dish"),
    ("2026-11-17", 1001.0, "Float id dish"),
    ("2026-11-17", "", "Empty id dish"),
    ("2026-11-17", None, "  No Id Dish  "),
    ("2026-01-02", 9, "Zupa"),
]


def _dish_key(meal_id: object, name: str) -> str:
    """The dish half of the id string, by the same rule as the Dart port.

    An ``int`` becomes its decimal string; a ``str`` is stripped. Everything
    else (``bool``, a float such as ``1001.0``, an empty or blank string, a
    missing id) falls back to the bank key. ``bool`` is tested first because
    ``isinstance(True, int)`` is true in Python and not in Dart.
    """
    key = ""
    if isinstance(meal_id, bool):
        key = ""
    elif isinstance(meal_id, int):
        key = str(meal_id)
    elif isinstance(meal_id, str):
        key = meal_id.strip()
    return key or name.strip().lower()


def build() -> dict[str, object]:
    """Return the fixture document."""
    cases = []
    for date, meal_id, name in _CASES:
        key = _dish_key(meal_id, name)
        cases.append(
            {
                "delivery_date": date,
                "delivery_meal_id": meal_id,
                "name": name,
                "dish_key": key,
                "name_string": f"kuchnia:{date}:{key}",
                "expected_id": str(
                    uuid.uuid5(uuid.NAMESPACE_URL, f"kuchnia:{date}:{key}")
                ),
            }
        )
    return {
        "_comment": (
            "Shared catering auto-log id fixture. Read by "
            "app/test/services/kuchnia_autolog_ids_test.dart (and the Python "
            "side later). Regenerate with "
            "scripts/build_kuchnia_autolog_fixture.py."
        ),
        "namespace": str(uuid.NAMESPACE_URL),
        "cases": cases,
    }


def main() -> None:
    """Write the fixture."""
    FIXTURE.write_text(
        json.dumps(build(), indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
