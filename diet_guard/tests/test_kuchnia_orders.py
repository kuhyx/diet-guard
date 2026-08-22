"""Tests for the panel's three-call walk to a day's menu.

Split from ``test_kuchnia_client.py`` for the repo's 250-line cap; the session,
credential and cookie-cache behaviour lives there.

The endpoint shape here is not the obvious one: ``.../deliveries/{id}/details``
404s despite its name, so the menu comes from
``company/general/menus/delivery/{deliveryId}/new``, keyed by the opaque id.
"""

from __future__ import annotations

import datetime
from unittest.mock import patch

import pytest

from diet_guard import _kuchnia_client, _kuchnia_config
from diet_guard._kuchnia_client import PanelSession
from diet_guard._kuchnia_errors import KuchniaError
from diet_guard._kuchnia_orders import fetch_dishes
from diet_guard.tests._kuchnia_fakes import (
    FakeResponse,
    FakeSession,
    fake_requests,
    menu_payload,
    order_payload,
    write_credentials,
)

DAY = datetime.date(2026, 8, 22)


@pytest.fixture
def creds() -> None:
    """Write a credentials file at the (redirected) config path."""
    write_credentials(_kuchnia_config.KUCHNIA_CREDENTIALS_FILE)


def _session_with(responses: list[FakeResponse]) -> FakeSession:
    return FakeSession(responses)


class TestFetchDishes:
    def _panel(self, responses: list[FakeResponse]) -> tuple[PanelSession, FakeSession]:
        session = _session_with(responses)
        with patch.object(_kuchnia_client, "requests", fake_requests(session)):
            return PanelSession(), session

    def test_walks_to_the_days_menu(self, creds: None) -> None:
        panel, session = self._panel(
            [
                FakeResponse(200, [1]),
                FakeResponse(200, order_payload(delivery_id=111)),
                FakeResponse(200, menu_payload(2)),
            ],
        )
        with patch.object(_kuchnia_client, "requests", fake_requests(session)):
            dishes = fetch_dishes(panel, DAY)
        assert len(dishes) == 2
        # The menu endpoint is keyed by the opaque deliveryId, never the date:
        # the date form 400s and the obvious `.../details` path 404s.
        assert any("menus/delivery/111/new" in url for _, url in session.calls)

    def test_no_active_order_is_not_an_error(self, creds: None) -> None:
        panel, session = self._panel([FakeResponse(200, [])])
        with patch.object(_kuchnia_client, "requests", fake_requests(session)):
            assert fetch_dishes(panel, DAY) == []

    def test_no_delivery_that_day_is_not_an_error(self, creds: None) -> None:
        panel, session = self._panel(
            [
                FakeResponse(200, [1]),
                FakeResponse(200, order_payload(date="2026-01-01")),
            ],
        )
        with patch.object(_kuchnia_client, "requests", fake_requests(session)):
            assert fetch_dishes(panel, DAY) == []

    def test_a_cancelled_delivery_is_skipped(self, creds: None) -> None:
        order = {
            "orderId": 1,
            "deliveries": [
                {"deliveryId": 111, "date": "2026-08-22", "deleted": True},
            ],
        }
        panel, session = self._panel([FakeResponse(200, [1]), FakeResponse(200, order)])
        with patch.object(_kuchnia_client, "requests", fake_requests(session)):
            assert fetch_dishes(panel, DAY) == []

    @pytest.mark.parametrize(
        "order",
        ["nope", {}, {"deliveries": "x"}, {"deliveries": [None]}],
    )
    def test_a_malformed_order_yields_nothing(self, creds: None, order: object) -> None:
        panel, session = self._panel([FakeResponse(200, [1]), FakeResponse(200, order)])
        with patch.object(_kuchnia_client, "requests", fake_requests(session)):
            assert fetch_dishes(panel, DAY) == []

    def test_an_unpublished_menu_is_reported_not_silently_empty(
        self, creds: None
    ) -> None:
        panel, session = self._panel(
            [
                FakeResponse(200, [1]),
                FakeResponse(200, order_payload()),
                FakeResponse(200, {"deliveryMenuMeal": []}),
            ],
        )
        with (
            patch.object(_kuchnia_client, "requests", fake_requests(session)),
            pytest.raises(KuchniaError, match="no usable dishes"),
        ):
            fetch_dishes(panel, DAY)

    def test_active_ids_may_be_junk(self, creds: None) -> None:
        panel, session = self._panel([FakeResponse(200, {"not": "a list"})])
        with patch.object(_kuchnia_client, "requests", fake_requests(session)):
            assert fetch_dishes(panel, DAY) == []
