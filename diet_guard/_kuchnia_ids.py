"""The id a catering dish gets when it is logged without a tap.

One formula on every device, so the PC's entry and the phone's entry for the
same delivered dish are the same record and the sync merge keeps one::

    uuid5(NAMESPACE_URL, f"kuchnia:{delivery date YYYY-MM-DD}:{dish key}")

The dish key is the panel's ``deliveryMealId`` (an ``int``, or a stripped
``str``); anything else -- a ``bool``, a float, a blank or missing id --
falls back to the lower-cased dish name. The phone's port and this module are
pinned by one fixture, ``tests/fixtures/kuchnia_autolog_ids.json``
(``scripts/build_kuchnia_autolog_fixture.py``), asserted by
``test_kuchnia_ids.py`` and ``app/test/services/kuchnia_autolog_ids_test.dart``.
"""

from __future__ import annotations

from datetime import date
import uuid


def dish_key(meal_id: object, name: str) -> str:
    """The dish half of the id string.

    ``bool`` is tested before ``int`` because ``isinstance(True, int)`` is
    true in Python and not in Dart; ``.lower()`` (not ``casefold``) matches
    the Dart port on the fixture's ASCII fallback names.
    """
    key = ""
    if isinstance(meal_id, bool):
        key = ""
    elif isinstance(meal_id, int):
        key = str(meal_id)
    elif isinstance(meal_id, str):
        key = meal_id.strip()
    return key or name.strip().lower()


def autolog_id(day: date | str, key: str) -> str:
    """The deterministic entry id for dish ``key`` delivered on ``day``."""
    stamp = day.isoformat() if isinstance(day, date) else day
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"kuchnia:{stamp}:{key}"))
