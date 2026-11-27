"""A local cache of the last successfully-fetched Kuchnia delivery.

Offline first: the panel is a third party that goes down, and a day's
delivery, once fetched, must stay usable without it. This module owns that
cache: :func:`save_delivery` after a successful fetch, :func:`load_delivery`
when the panel fails or the day was already fetched.

Every failure mode is "no cache": a missing file, bad JSON, another day's
delivery, or a half-written record all mean "fetch again", which is always
safe. The phone keeps the same file (``KuchniaAutoLog.store``).
"""

from __future__ import annotations

import dataclasses
import json
import logging
from typing import TYPE_CHECKING

from diet_guard import _constants
from diet_guard._kuchnia_parse import Dish

if TYPE_CHECKING:  # pragma: no cover - typing only
    from collections.abc import Sequence
    from datetime import date

_LOGGER = logging.getLogger(__name__)


def load_delivery(day: date) -> list[Dish]:
    """Return the dishes cached for ``day``'s delivery, or ``[]``.

    Any unreadable, malformed or foreign-day cache is treated as "no cache"
    rather than an error: the caller falls back to the panel fetch, which is
    strictly better than a stale import.
    """
    path = _constants.KUCHNIA_DELIVERY_CACHE_FILE
    try:
        if not path.exists():
            return []
        raw = path.read_text()
    except OSError:
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(data, dict) or data.get("day") != day.isoformat():
        return []
    dishes = data.get("dishes")
    if not isinstance(dishes, list):
        return []
    out: list[Dish] = []
    for item in dishes:
        if not isinstance(item, dict):
            continue
        try:
            out.append(Dish(**item))
        except TypeError:
            continue
    return out


def save_delivery(day: date, dishes: Sequence[Dish]) -> None:
    """Persist ``day``'s delivery so a later outage can still import it.

    Best-effort: a write failure only costs the fallback, so it is logged
    and swallowed, never raised into the import path. The write goes to a
    sibling ``.tmp`` and is atomically renamed, so a half-written file can
    never poison :func:`load_delivery`.
    """
    path = _constants.KUCHNIA_DELIVERY_CACHE_FILE
    payload = json.dumps(
        {
            "day": day.isoformat(),
            "dishes": [dataclasses.asdict(d) for d in dishes],
        }
    )
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(payload)
        tmp.replace(path)
    except OSError:
        _LOGGER.warning("could not save the kitchen delivery cache")
