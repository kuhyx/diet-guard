#!/usr/bin/env python3
"""Capture the Kuchnia Wikinga panel's API shape so the importer can be written.

The panel (``panel.kuchniavikinga.pl``) is a white-labelled *Dietly* React SPA
with no published API.  Its endpoint map was recovered by grepping the Vite
bundles, which settled the URLs, the auth scheme and the header set -- but not
the *response shape*.  This script fetches the real payloads so
``diet_guard._kuchnia_parse`` can be written against captured JSON instead of
against a guess.

It lives in ``scripts/`` rather than as a ``diet_guard`` subcommand on purpose:
the package carries a 100% branch-coverage gate, and a probe inside it would
need tests written against the very payload it exists to discover.

Three questions the capture must answer, because each changes the mapping code:

* **Are macros per portion or per 100 g?**  The highest-risk unknown -- a
  per-100 g figure stored as a portion total silently under-reports every meal.
  Look for a weight/grams field next to ``calories``.
* Are the macro fields on the meal object, or nested under something like
  ``nutritionalValues``?
* Does the order object embed its deliveries, or is a separate call needed?

Nothing here writes to ``diet_guard`` state; the only output is a JSON dump.

Usage:
    python3 scripts/probe_kuchnia.py
"""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
import json
from pathlib import Path
import sys
from typing import Any

from probe_kuchnia_auth import prompt_credentials, remember_session
from probe_kuchnia_shape import describe, find_delivery_id
import requests

ORIGIN = "https://panel.kuchniavikinga.pl"
COMPANY = "kuchniavikinga"

#: Both candidate bases. The bundles define an RTK Query slice on ``/api`` and a
#: ``configSlice.baseUrl`` of ``/api/panel``, with code deriving one from the
#: other -- so which one ``auth/login`` answers on is decided here, not guessed.
LOGIN_BASES = (f"{ORIGIN}/api", f"{ORIGIN}/api/panel")

TIMEOUT = 20.0


def emit(text: str = "") -> None:
    """Write one progress line to stdout.

    A thin wrapper over ``sys.stdout.write``, mirroring ``diet_guard._cli._emit``
    so genuine operator output does not trip ruff's ``T201`` (no ``print``)
    without resorting to a suppression.  The progress lines are the point of an
    interactive probe -- they are what tells the operator which base answered
    and how far the walk got before something returned a non-200.
    """
    sys.stdout.write(f"{text}\n")


def login(session: requests.Session, username: str, password: str) -> str | None:
    """Try each candidate base until one accepts the credentials.

    The bundles show a form-urlencoded body, not JSON -- ``data=`` rather than
    ``json=`` -- and let ``requests`` set the content type.

    Args:
        session: The session that will carry the resulting cookies.
        username: Panel login.
        password: Panel password.

    Returns:
        The base URL that worked, or None when both were rejected.
    """
    for base in LOGIN_BASES:
        response = session.post(
            f"{base}/auth/login",
            data={"username": username, "password": password},
            timeout=TIMEOUT,
        )
        emit(f"  {base}/auth/login -> {response.status_code}")
        if response.ok:
            names = sorted({cookie.name for cookie in session.cookies})
            emit(f"  cookies received: {names or '(none)'}")
            return base
    return None


def walk(session: requests.Session, base: str) -> dict[str, Any]:
    """Follow active-ids -> order -> delivery details, capturing each payload.

    Args:
        session: A logged-in session.
        base: The API base that accepted the login.

    Returns:
        The captured payloads, keyed by step.
    """
    captured: dict[str, Any] = {}

    active = session.get(f"{base}/company/customer/order/active-ids", timeout=TIMEOUT)
    captured["active_ids"] = describe(active)
    emit(f"  active-ids -> {active.status_code}")
    if not active.ok:
        return captured

    ids = active.json()
    order_id = ids[0] if isinstance(ids, list) and ids else None
    if order_id is None:
        emit("  no active orders -- nothing further to capture.")
        return captured

    order = session.get(f"{base}/company/customer/order/{order_id}", timeout=TIMEOUT)
    captured["order"] = describe(order)
    emit(f"  order/{order_id} -> {order.status_code}")
    if not order.ok:
        return captured

    delivery_id = find_delivery_id(order.json())
    captured["delivery_id_found"] = delivery_id
    if delivery_id is None:
        emit("  no deliveryId spotted in the order payload -- inspect it by hand.")
        return captured

    details = session.get(
        f"{base}/company/customer/order/{order_id}/deliveries/{delivery_id}/details",
        timeout=TIMEOUT,
    )
    captured["delivery_details"] = describe(details)
    emit(f"  deliveries/{delivery_id}/details -> {details.status_code}")
    return captured


def build_session() -> requests.Session:
    """Return a session with the headers the panel requires on every call."""
    session = requests.Session()
    # No session-level Content-Type: login is form-urlencoded and a sticky JSON
    # default would mislabel its body. ``requests`` sets it per request.
    session.headers.update(
        {
            "company-id": COMPANY,
            "X-Launcher-Type": "BROWSER_PANEL",
            "User-Agent": "diet_guard/1.0 (personal diet tracker)",
            "Accept": "application/json",
        },
    )
    return session


def main() -> int:
    """Run the probe and write the capture.

    Returns:
        0 on success, 1 when login failed.
    """
    parser = argparse.ArgumentParser(description="Probe the Kuchnia Wikinga panel.")
    parser.add_argument(
        "--out",
        default="kuchnia_probe.json",
        help="Where to write the captured payloads.",
    )
    args = parser.parse_args()

    # Prompted, never an argv flag: a password in argv lands in shell history
    # and in every ps listing on the machine.
    username, password = prompt_credentials()

    session = build_session()
    emit("Trying login bases...")
    base = login(session, username, password)
    if base is None:
        emit("Login rejected on both bases -- check the credentials.")
        return 1

    # Cache the session so the follow-up probes do not ask again.
    remember_session(session)

    xsrf = session.cookies.get("XSRF-TOKEN")
    emit(f"XSRF-TOKEN cookie present: {xsrf is not None}")
    if xsrf is not None:
        session.headers["X-XSRF-TOKEN"] = xsrf

    emit("Walking the order endpoints...")
    captured = walk(session, base)

    out = Path(args.out)
    out.write_text(
        json.dumps(
            {
                "captured_at": datetime.now(tz=UTC).isoformat(),
                "login_base": base,
                "xsrf_cookie_present": xsrf is not None,
                "steps": captured,
            },
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    emit(f"\nWrote {out.resolve()}")
    emit("Check: are macros per portion or per 100 g? Is there a grams/weight field?")
    return 0


if __name__ == "__main__":
    sys.exit(main())
