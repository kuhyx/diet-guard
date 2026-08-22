"""Shared fakes for the catering-import tests.

Not a ``test_`` module: these are fixtures-by-hand imported by the
``test_kuchnia_*`` files, and pytest must not collect them as tests. The repo
already excludes this naming pattern from the ``name-tests-test`` hook.

The fake stands in for ``requests`` at the module seam
(``patch.object(_kuchnia_client, "requests", ...)``), which is the same shape
``_estimator_off``'s tests use and the reason both modules resolve the name
through ``sys.modules`` rather than binding it at import.
"""

from __future__ import annotations

import json
from types import SimpleNamespace
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterator
    from pathlib import Path


class FakeResponse:
    """The slice of ``requests.Response`` the client actually touches."""

    def __init__(
        self, status: int = 200, payload: object = None, *, text: str = ""
    ) -> None:
        """Build a response with ``status`` and either JSON or raw text."""
        self.status_code = status
        self._payload = payload
        self.text = text or (json.dumps(payload) if payload is not None else "")

    @property
    def ok(self) -> bool:
        """Mirror ``requests``: 2xx and 3xx are OK."""
        return self.status_code < 400

    def json(self) -> object:
        """Return the decoded payload, raising like ``requests`` on non-JSON."""
        if self._payload is None:
            msg = "no json"
            raise ValueError(msg)
        return self._payload


class FakeCookieJar(dict[str, str]):
    """A cookie jar with the two methods the client uses."""

    def set(self, name: str, value: str, **_kwargs: object) -> None:
        """Store a cookie, ignoring domain/path keywords."""
        self[name] = value


class FakeSession:
    """Records requests and replays queued responses in order."""

    def __init__(self, responses: list[FakeResponse] | None = None) -> None:
        """Queue ``responses`` to be returned one per request."""
        self.headers: dict[str, str] = {}
        self.cookies = FakeCookieJar()
        self.calls: list[tuple[str, str]] = []
        self.bodies: list[dict[str, str]] = []
        self._responses: Iterator[FakeResponse] = iter(responses or [])
        self.login_cookie: str | None = "session-abc"
        self.raise_on_request: Exception | None = None

    def request(
        self,
        method: str,
        url: str,
        data: dict[str, str] | None = None,
        timeout: float | None = None,
    ) -> FakeResponse:
        """Return the next queued response, recording the call and body."""
        del timeout
        if self.raise_on_request is not None:
            raise self.raise_on_request
        self.calls.append((method, url))
        if data is not None:
            self.bodies.append(data)
        if method == "POST" and url.endswith("auth/login") and self.login_cookie:
            self.cookies.set("SESSION", self.login_cookie)
        try:
            return next(self._responses)
        except StopIteration:
            return FakeResponse(200, {})


def fake_requests(session: FakeSession) -> SimpleNamespace:
    """Return a stand-in for the ``requests`` module itself.

    A namespace rather than a class: ``requests.Session`` is capitalised, and
    defining a method by that name would need an ``N802`` suppression for no
    benefit. ``RequestException`` is included because the client catches it.
    """
    return SimpleNamespace(
        Session=lambda: session,
        RequestException=FakeRequestError,
    )


class FakeRequestError(Exception):
    """Stands in for ``requests.RequestException``."""


def write_credentials(path: Path, user: str = "me@example.com", pw: str = "pw") -> None:
    """Write a credentials file in the two-line format the reader expects."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"{user}\n{pw}\n", encoding="utf-8")


#: A menu payload shaped like the live one, macros per portion.
def menu_payload(count: int = 2) -> dict[str, object]:
    """Return a ``menus/delivery/{id}/new`` body with ``count`` valid dishes."""
    return {
        "deliveryMenuMeal": [
            {
                "menuMealName": f"Danie {index}",
                "mealName": "Obiad",
                "mealPriority": index,
                "nutrition": {
                    "weight": 300.0,
                    "calories": 400.0,
                    "protein": 25.0,
                    "carbohydrate": 50.0,
                    "fat": 11.1,
                },
            }
            for index in range(1, count + 1)
        ],
    }


def order_payload(
    delivery_id: int = 111, date: str = "2026-08-22"
) -> dict[str, object]:
    """Return an order body embedding one delivery on ``date``."""
    return {
        "orderId": 1,
        "deliveries": [
            {"deliveryId": delivery_id, "date": date, "deleted": False},
        ],
    }
