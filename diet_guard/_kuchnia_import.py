"""Fetch the day's catering dishes and bank them.

Holds the module's single fail-closed boundary, :func:`refresh_delivery`: every
:class:`~diet_guard._kuchnia_errors.KuchniaError` is turned into a reason string
here, so no caller can be broken by a catering outage.  That is the same idiom
as ``pull_peer_logs`` and ``publish_after_log``.

Imports go **only** to the curated bank
(:mod:`diet_guard._foodbank_manual`).  The derived bank is rewritten from the
log on every meal, so anything written there would vanish at the next entry.

The idempotency guard is load-bearing and easy to get wrong.
``add_manual_entry`` restamps ``t`` unconditionally and rewrites the whole
file, and the sync merge derives each record's HLC from that ``t`` -- so
calling it for unchanged dishes would republish the *entire* curated bank to
every peer on every refresh.  :func:`bank_dishes` therefore compares the
nutritional fields first and writes only what actually differs.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from diet_guard._foodbank_manual import add_manual_entry, read_manual_bank
from diet_guard._kuchnia_client import PanelSession
from diet_guard._kuchnia_config import last_import_day, record_import_day
from diet_guard._kuchnia_errors import KuchniaError
from diet_guard._kuchnia_orders import fetch_dishes

if TYPE_CHECKING:  # pragma: no cover - typing only
    from collections.abc import Sequence
    from datetime import date

    from diet_guard._kuchnia_parse import Dish

#: Fields compared to decide whether a bank record changed. ``t`` is excluded
#: deliberately -- it is the edit stamp, not part of the record's meaning, and
#: including it would make every comparison differ.
_COMPARED = ("desc", "kcal", "protein_g", "carbs_g", "fat_g", "grams")


def dish_to_record(dish: Dish) -> dict[str, object]:
    """Return the curated-bank record for ``dish``.

    ``count`` is 0: the bank's count ranks foods by how often they were
    *eaten*, and a delivered dish has not been eaten yet. Logging it later
    bumps the derived bank's own count normally.
    """
    return {
        "desc": dish.name,
        "kcal": dish.kcal,
        "protein_g": dish.protein_g,
        "carbs_g": dish.carbs_g,
        "fat_g": dish.fat_g,
        "grams": dish.grams,
        "count": 0,
    }


def _matches(existing: dict[str, object], record: dict[str, object]) -> bool:
    """Return True when the banked record already says the same thing."""
    return all(existing.get(key) == record.get(key) for key in _COMPARED)


def bank_dishes(dishes: Sequence[Dish]) -> int:
    """Add dishes to the curated bank, skipping ones already banked unchanged.

    Args:
        dishes: The dishes to bank.

    Returns:
        How many records were actually written.
    """
    bank = read_manual_bank()
    written = 0
    for dish in dishes:
        record = dish_to_record(dish)
        existing = bank.get(dish.name.strip().casefold())
        if isinstance(existing, dict) and _matches(existing, record):
            continue
        add_manual_entry(dish.name, record)
        written += 1
    return written


def refresh_delivery(day: date) -> tuple[list[Dish], str | None]:
    """Fetch ``day``'s dishes and bank them, never raising.

    Args:
        day: The delivery date to fetch.

    Returns:
        ``(dishes, None)`` on success, or ``([], reason)`` when the catering
        panel could not be read. Callers surface the reason and carry on.
    """
    try:
        session = PanelSession()
        session.authenticate()
        dishes = fetch_dishes(session, day)
    except KuchniaError as exc:
        return [], str(exc)
    bank_dishes(dishes)
    return dishes, None


def refresh_delivery_once(day: date) -> tuple[list[Dish], str | None]:
    """Fetch ``day``'s dishes unless today's have already been fetched.

    The automatic triggers -- the gate opening, and the after-log publish --
    can both fire many times a day, and each :func:`refresh_delivery` is a full
    login plus a three-request walk against a third party. This wrapper makes
    them cheap: the first call of the day pays, the rest are free.

    The marker is a date on disk rather than a look in the curated bank. The
    bank is keyed by dish name, so it can answer "is this dish known?" but
    never "has today's delivery been fetched?" -- and knowing today's names
    requires the very fetch being avoided.

    The CLI deliberately does **not** use this: an explicit ``diet-guard
    kuchnia`` should always go and look.

    Args:
        day: The delivery date to fetch.

    Returns:
        ``([], None)`` when today was already fetched -- "nothing new", not an
        error. Otherwise whatever :func:`refresh_delivery` returns.
    """
    stamp = day.isoformat()
    if last_import_day() == stamp:
        return [], None
    dishes, reason = refresh_delivery(day)
    if reason is None:
        # Only a clean fetch counts: an outage must not suppress the retry.
        record_import_day(stamp)
    return dishes, reason
