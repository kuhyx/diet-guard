#!/usr/bin/env python3
"""Second probe pass: find which URL form returns a day's meals, and its shape.

The first pass (:mod:`probe_kuchnia`) settled login, the API base and the order
payload, but its ``deliveries/{id}/details`` call 404'd -- it had picked the
first delivery in document order, which was weeks in the future.  It also found
no ``XSRF-TOKEN`` cookie, only ``SESSION``.

So two questions remain, and both are answered by trying rather than guessing:

* Does ``details`` key on the opaque ``deliveryId`` or on the ``YYYY-MM-DD``
  date?  The bundles pass a variable named ``deliveryId``, but the 404 means the
  panel may want something else -- or that endpoint may only serve *past*
  deliveries.
* Where do dish names and macros actually live?  The order's ``deliveryMeals``
  carry only ids (``dietCaloriesMealId``), so the names must come from
  ``details`` or from the menu endpoint.

Run this after ``probe_kuchnia.py``; it re-uses that capture to pick sensible
delivery ids instead of prompting for them.

Usage:
    python3 scripts/probe_kuchnia_details.py [--capture kuchnia_probe.json]
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
from typing import TYPE_CHECKING, Any

from probe_kuchnia import ORIGIN, TIMEOUT, build_session, emit, login
from probe_kuchnia_auth import (
    attach_cached_session,
    clear_session_cookie,
    prompt_credentials,
    remember_session,
)
from probe_kuchnia_shape import describe

if TYPE_CHECKING:
    import requests

#: Candidate URL templates for a single day's meals. ``{order}`` is the order
#: id, ``{key}`` is whatever identifies the day -- id or date, which is exactly
#: what this probe is here to determine.
CANDIDATES = (
    "company/customer/order/{order}/deliveries/{key}/details",
    "company/general/menus/delivery/{key}/new",
    "company/customer/order/{order}/deliveries/{key}/eta",
)


def pick_deliveries(capture: dict[str, Any]) -> list[dict[str, Any]]:
    """Return today's delivery and its neighbours from a first-pass capture.

    A past, a current and a future delivery are all tried: if ``details`` only
    serves days that have already been delivered, testing today alone would
    report a false negative.

    Args:
        capture: The JSON written by ``probe_kuchnia.py``.

    Returns:
        Up to three delivery objects, oldest first.
    """
    order = capture["steps"]["order"]["body"]
    deliveries = sorted(order["deliveries"], key=lambda item: str(item["date"]))
    today = datetime.now(tz=timezone.utc).astimezone().date().isoformat()
    past = [item for item in deliveries if str(item["date"]) < today]
    current = [item for item in deliveries if str(item["date"]) == today]
    future = [item for item in deliveries if str(item["date"]) > today]
    return past[-1:] + current + future[:1]


def probe_forms(
    session: requests.Session,
    base: str,
    order_id: object,
    delivery: dict[str, Any],
) -> dict[str, Any]:
    """Try every candidate URL for one delivery, keyed by id and by date.

    Args:
        session: A logged-in session.
        base: The API base that accepted the login.
        order_id: The active order's id.
        delivery: One delivery object from the order payload.

    Returns:
        A record per attempted URL.
    """
    results: dict[str, Any] = {}
    keys = {"by_id": delivery["deliveryId"], "by_date": delivery["date"]}
    for template in CANDIDATES:
        for label, key in keys.items():
            path = template.format(order=order_id, key=key)
            response = session.get(f"{base}/{path}", timeout=TIMEOUT)
            emit(f"    {label:8} {path} -> {response.status_code}")
            if response.ok:
                results[f"{template}|{label}"] = describe(response)
    return results


def _session_works(session: requests.Session, base: str, order_id: object) -> bool:
    """Return True when the attached cookie still authenticates.

    A cached cookie that has expired looks identical to a good one until it is
    used, so it is checked against a cheap authenticated endpoint before the
    probe commits to it -- otherwise every subsequent call 401s and the run
    reports a shape problem that is really an auth problem.
    """
    probe = session.get(f"{base}/company/customer/order/{order_id}", timeout=TIMEOUT)
    return probe.ok


def main() -> int:
    """Run the second probe pass and write its capture.

    Returns:
        0 on success, 1 when login failed.
    """
    parser = argparse.ArgumentParser(description="Probe the delivery-details shape.")
    parser.add_argument("--capture", default="kuchnia_probe.json")
    parser.add_argument("--out", default="kuchnia_probe_details.json")
    args = parser.parse_args()

    capture = json.loads(Path(args.capture).read_text(encoding="utf-8"))
    order_id = capture["steps"]["order"]["body"]["orderId"]
    targets = pick_deliveries(capture)
    emit(f"Order {order_id}; trying {len(targets)} deliveries.")

    session = build_session()
    base = f"{ORIGIN}/api"
    if attach_cached_session(session) and _session_works(session, base, order_id):
        emit("Reusing the cached session -- no login needed.")
    else:
        # Either no cache, or the cached cookie has expired. Drop it and log in
        # once; the fresh cookie is cached so the next run is prompt-free again.
        clear_session_cookie()
        username, password = prompt_credentials()
        resolved = login(session, username, password)
        if resolved is None:
            emit("Login rejected -- check the credentials.")
            return 1
        base = resolved
        remember_session(session)

    # No XSRF-TOKEN cookie was issued on the first pass, so the CSRF echo is
    # simply skipped when absent rather than sent empty.
    xsrf = session.cookies.get("XSRF-TOKEN")
    if xsrf is not None:
        session.headers["X-XSRF-TOKEN"] = xsrf

    found: dict[str, Any] = {}
    for delivery in targets:
        emit(f"  delivery {delivery['deliveryId']} ({delivery['date']}):")
        found[str(delivery["date"])] = probe_forms(session, base, order_id, delivery)

    Path(args.out).write_text(
        json.dumps(
            {"order_id": order_id, "results": found}, indent=2, ensure_ascii=False
        ),
        encoding="utf-8",
    )
    emit(f"\nWrote {Path(args.out).resolve()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
