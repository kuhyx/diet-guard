"""Walk the panel's endpoints to today's delivered dishes.

Three calls, and the shape of the walk is not what the endpoint names suggest:

1. ``company/customer/order/active-ids`` -> ``[orderId]``.
2. ``company/customer/order/{orderId}`` -> the order, which **embeds every
   delivery** with its date.  No enumeration call is needed, but the embedded
   ``deliveryMeals`` carry ids only -- no dish names, no macros.
3. ``company/general/menus/delivery/{deliveryId}/new`` -> the day's actual
   menu, with names and per-portion nutrition.

Step 3 is the important correction: the obvious-looking
``.../deliveries/{id}/details`` **404s** (and 400s when keyed by date), which
was confirmed against three separate delivery days.  The menu endpoint is keyed
by the opaque ``deliveryId``, never by the date.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from diet_guard._kuchnia_errors import KuchniaError
from diet_guard._kuchnia_parse import parse_menu

if TYPE_CHECKING:  # pragma: no cover - typing only
    from datetime import date

    from diet_guard._kuchnia_client import PanelSession
    from diet_guard._kuchnia_parse import Dish


def _active_order_id(session: PanelSession) -> object | None:
    """Return the first active order id, or None when there is no active order."""
    payload = session.get_json("company/customer/order/active-ids")
    if not isinstance(payload, list) or not payload:
        return None
    return payload[0]


def _delivery_id_for(payload: object, wanted: str) -> object | None:
    """Return the delivery id whose date is ``wanted``.

    Args:
        payload: The decoded order.
        wanted: An ISO ``YYYY-MM-DD`` date.

    Returns:
        The delivery id, or None when that day has no (undeleted) delivery.
    """
    if not isinstance(payload, dict):
        return None
    deliveries = payload.get("deliveries")
    if not isinstance(deliveries, list):
        return None
    for delivery in deliveries:
        if not isinstance(delivery, dict):
            continue
        # ``deleted`` marks a cancelled day; it still appears in the list.
        if delivery.get("deleted"):
            continue
        if str(delivery.get("date")) == wanted:
            return delivery.get("deliveryId")
    return None


def fetch_dishes(session: PanelSession, day: date) -> list[Dish]:
    """Return the dishes delivered on ``day``.

    Args:
        session: An authenticated session.
        day: The delivery date to fetch.

    Returns:
        The day's dishes, empty when nothing is delivered that day.

    Raises:
        KuchniaError: When the panel cannot be read.
    """
    order_id = _active_order_id(session)
    if order_id is None:
        return []
    order = session.get_json(f"company/customer/order/{order_id}")
    delivery_id = _delivery_id_for(order, day.isoformat())
    if delivery_id is None:
        return []
    menu = session.get_json(f"company/general/menus/delivery/{delivery_id}/new")
    dishes = parse_menu(menu)
    if not dishes:
        # A delivery exists but nothing survived parsing: either the menu is
        # not published yet, or its units failed the consistency check. Both
        # are "no data", not a crash -- but they are worth distinguishing from
        # "no delivery" in the caller's message.
        msg = f"catering menu for {day.isoformat()} has no usable dishes"
        raise KuchniaError(msg)
    return dishes
