#!/usr/bin/env python3
"""Payload shaping for :mod:`probe_kuchnia`: redaction and delivery-id search.

Split out of ``probe_kuchnia.py`` to keep both files under the repo's 250-line
cap.  Nothing here performs I/O, which also makes the redaction rule -- the
part with a real security consequence -- readable on its own.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    import requests

#: Keys whose *values* never reach the dump. Names are kept: knowing a cookie is
#: called ``XSRF-TOKEN`` is the point; knowing its value is a liability, and the
#: capture is a plain file the operator may well paste into a chat window.
SECRET_KEYS = frozenset(
    {"password", "token", "accesstoken", "refreshtoken", "authorization", "cookie"},
)
REDACTED = "<redacted>"

#: How much of a non-JSON body to keep -- enough to recognise an HTML error page
#: or a proxy banner without pasting an entire document into the capture.
BODY_EXCERPT_CHARS = 500


def redact(value: object) -> object:
    """Return ``value`` with any secret-looking field replaced by a placeholder.

    Args:
        value: Arbitrary decoded JSON.

    Returns:
        The same structure with secret values masked.
    """
    if isinstance(value, dict):
        return {
            key: REDACTED if str(key).casefold() in SECRET_KEYS else redact(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


def describe(response: requests.Response) -> dict[str, Any]:
    """Summarise ``response`` for the dump, body included when it is JSON.

    Args:
        response: The response to describe.

    Returns:
        A JSON-serialisable record of status, cookie names and body.
    """
    try:
        body: object = redact(response.json())
    except ValueError:
        # Not JSON: an HTML login redirect or an error page. Keep an excerpt --
        # which of those it is answers "did the session actually authenticate?".
        body = response.text[:BODY_EXCERPT_CHARS]
    return {
        "url": response.url,
        "status": response.status_code,
        "set_cookie_names": sorted({cookie.name for cookie in response.cookies}),
        "body": body,
    }


def find_delivery_id(payload: object) -> object:
    """Return the first ``deliveryId`` found anywhere in ``payload``.

    The bundles treat this id as opaque and never derive it from a date, so it
    is located by searching the order payload rather than constructed from
    today's date -- which is exactly the assumption that would break the walk.

    Args:
        payload: Decoded order JSON.

    Returns:
        The first delivery id encountered, or None.
    """
    if isinstance(payload, dict):
        for key, value in payload.items():
            if key == "deliveryId" and value is not None:
                return value
            found = find_delivery_id(value)
            if found is not None:
                return found
    elif isinstance(payload, list):
        for item in payload:
            found = find_delivery_id(item)
            if found is not None:
                return found
    return None
