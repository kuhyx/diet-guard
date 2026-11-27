"""The Kuchnia delivery cache: an outage falls back to the last fetched day.

Every on-disk write in these tests lands in the conftest-redirected tmp
state; the two ``pathlib`` patches below are the only fault injection.
"""

from __future__ import annotations

from contextlib import contextmanager
import dataclasses
from datetime import date
import json
from typing import TYPE_CHECKING
from unittest.mock import Mock, patch

from diet_guard import _constants
from diet_guard._kuchnia_config import record_import_day
from diet_guard._kuchnia_delivery_cache import load_delivery, save_delivery
from diet_guard._kuchnia_errors import KuchniaError
from diet_guard._kuchnia_import import refresh_delivery, refresh_delivery_once
from diet_guard._kuchnia_parse import Dish

if TYPE_CHECKING:
    from collections.abc import Iterator

DAY = date(2026, 11, 27)


def _dish() -> Dish:
    return Dish("Osobiste danie", 300.0, 10.0, 20.0, 2.0, 250.0, 1, "obiad")


def _write_cache(payload: object) -> None:
    _constants.KUCHNIA_DELIVERY_CACHE_FILE.write_text(json.dumps(payload))


# --- load_delivery ----------------------------------------------------------


def test_save_then_load_round_trip() -> None:
    save_delivery(DAY, [_dish()])
    assert load_delivery(DAY) == [_dish()]


def test_load_missing_file() -> None:
    assert load_delivery(DAY) == []


def test_load_wrong_day() -> None:
    save_delivery(DAY, [_dish()])
    assert load_delivery(date(2026, 11, 28)) == []


def test_load_malformed_json() -> None:
    _constants.KUCHNIA_DELIVERY_CACHE_FILE.write_text("not json")
    assert load_delivery(DAY) == []


def test_load_top_level_not_a_dict() -> None:
    _write_cache([])
    assert load_delivery(DAY) == []


def test_load_dishes_not_a_list() -> None:
    _write_cache({"day": DAY.isoformat(), "dishes": "nope"})
    assert load_delivery(DAY) == []


def test_load_skips_non_dict_items() -> None:
    _write_cache(
        {
            "day": DAY.isoformat(),
            "dishes": [42, dataclasses.asdict(_dish())],
        }
    )
    assert load_delivery(DAY) == [_dish()]


def test_load_skips_unknown_key_items() -> None:
    _write_cache(
        {
            "day": DAY.isoformat(),
            "dishes": [{"bogus_key": 1}, dataclasses.asdict(_dish())],
        }
    )
    assert load_delivery(DAY) == [_dish()]


def test_load_oserror_on_read() -> None:
    save_delivery(DAY, [_dish()])
    with patch("pathlib.Path.read_text", side_effect=OSError("io")):
        assert load_delivery(DAY) == []


def test_save_oserror_on_write() -> None:
    with patch("pathlib.Path.write_text", side_effect=OSError("io")):
        save_delivery(DAY, [_dish()])  # must not raise
    assert not _constants.KUCHNIA_DELIVERY_CACHE_FILE.exists()


# --- refresh_delivery -------------------------------------------------------


@contextmanager
def _patched_fetch(**mock_kwargs: object) -> Iterator[Mock]:
    """Patch the panel login and the dish walk; yield the ``fetch_dishes`` mock."""
    with (
        patch("diet_guard._kuchnia_import.PanelSession", return_value=Mock()),
        patch("diet_guard._kuchnia_import.fetch_dishes", **mock_kwargs) as fetch,
    ):
        yield fetch


def test_refresh_delivery_success_saves_cache() -> None:
    with _patched_fetch(return_value=[_dish()]):
        dishes, reason = refresh_delivery(DAY)
    assert dishes == [_dish()]
    assert reason is None
    assert load_delivery(DAY) == [_dish()]


def test_refresh_delivery_outage_falls_back_to_cache() -> None:
    save_delivery(DAY, [_dish()])
    with _patched_fetch(side_effect=KuchniaError("down")):
        dishes, reason = refresh_delivery(DAY)
    assert dishes == [_dish()]
    assert reason is None


def test_refresh_delivery_outage_without_cache_reports_reason() -> None:
    with _patched_fetch(side_effect=KuchniaError("down")):
        dishes, reason = refresh_delivery(DAY)
    assert dishes == []
    assert reason == "down"


def test_refresh_delivery_success_with_no_dishes_skips_cache() -> None:
    with _patched_fetch(return_value=[]):
        dishes, reason = refresh_delivery(DAY)
    assert dishes == []
    assert reason is None
    assert load_delivery(DAY) == []


# --- refresh_delivery_once --------------------------------------------------


def test_refresh_delivery_once_after_import_day_reads_cache() -> None:
    record_import_day(DAY.isoformat())
    save_delivery(DAY, [_dish()])
    with patch("diet_guard._kuchnia_import.fetch_dishes") as fetch:
        dishes, reason = refresh_delivery_once(DAY)
        fetch.assert_not_called()
    assert dishes == [_dish()]
    assert reason is None
