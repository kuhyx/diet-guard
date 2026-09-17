"""Tests for _phone_weight.py -- the phone's weigh-in into the stored weight.

The on-disk budget is redirected by conftest's ``_isolate_state``.
"""

from __future__ import annotations

from dataclasses import dataclass
import sys
from unittest.mock import patch

import pytest

from diet_guard import _phone_weight
from diet_guard._budget import read_raw_record, write_raw_record
from diet_guard._budget_derived import budget_weight
from diet_guard._phone_weight import refresh_weight_from_phone, update_weight


@dataclass(frozen=True)
class FakeWeight:
    """Shape of ``wake_alarm._weight.Weight``, without the dependency."""

    date: str
    kg: float
    device_id: str = "phone"


class FakeWeightModule:
    """Stand-in for ``wake_alarm._weight`` with a canned ``latest_weight``."""

    def __init__(self, weight: FakeWeight | None) -> None:
        self.weight = weight
        self.calls = 0

    def latest_weight(self) -> FakeWeight | None:
        self.calls += 1
        return self.weight


def _seed(weight: float | None, edited: str) -> None:
    record: dict[str, object] = {"v": 2, "b": 2000, "t": edited}
    if weight is not None:
        record["w"] = weight
    write_raw_record(record)


@pytest.fixture
def phone(request: pytest.FixtureRequest) -> FakeWeightModule:
    module = FakeWeightModule(getattr(request, "param", None))
    with patch.object(_phone_weight, "import_module", return_value=module):
        yield module


def _lines_after(module: FakeWeightModule, weight: FakeWeight | None) -> list[str]:
    module.weight = weight
    lines: list[str] = []
    refresh_weight_from_phone(lines.append)
    return lines


class TestUpdateWeight:
    def test_sets_weight_and_refreshes_the_edit_stamp(self) -> None:
        _seed(78.5, "2026-08-15T18:38:45+02:00")
        assert update_weight(72.44) is True
        record = read_raw_record()
        assert record is not None
        assert record["w"] == 72.4
        assert record["b"] == 2000
        assert str(record["t"]).startswith("20")
        assert record["t"] != "2026-08-15T18:38:45+02:00"
        assert budget_weight() == 72.4

    def test_without_a_budget_writes_nothing(self) -> None:
        assert update_weight(72.4) is False
        assert read_raw_record() is None


class TestRefreshWeightFromPhone:
    def test_applies_a_newer_weigh_in_and_reports_it(
        self, phone: FakeWeightModule
    ) -> None:
        _seed(78.5, "2026-08-15T18:38:45+02:00")
        lines = _lines_after(phone, FakeWeight("2026-09-17", 72.4))
        assert lines == ["weight: 72.4 kg from the phone (2026-09-17)."]
        assert budget_weight() == 72.4

    def test_applies_when_the_record_has_no_weight_yet(
        self, phone: FakeWeightModule
    ) -> None:
        _seed(None, "2026-08-15T18:38:45+02:00")
        assert _lines_after(phone, FakeWeight("2026-09-17", 72.4))
        assert budget_weight() == 72.4

    def test_applies_when_the_record_has_no_edit_stamp(
        self, phone: FakeWeightModule
    ) -> None:
        write_raw_record({"v": 1, "b": 2000})
        assert _lines_after(phone, FakeWeight("2026-09-17", 72.4))
        assert budget_weight() == 72.4

    def test_skips_a_weigh_in_from_the_budget_edit_day_or_earlier(
        self, phone: FakeWeightModule
    ) -> None:
        _seed(78.5, "2026-09-17T21:30:00+02:00")
        assert _lines_after(phone, FakeWeight("2026-09-17", 72.4)) == []
        assert _lines_after(phone, FakeWeight("2026-09-16", 72.4)) == []
        assert budget_weight() == 78.5

    def test_skips_a_weight_that_matches_within_tolerance(
        self, phone: FakeWeightModule
    ) -> None:
        _seed(72.4, "2026-08-15T18:38:45+02:00")
        assert _lines_after(phone, FakeWeight("2026-09-17", 72.44)) == []
        record = read_raw_record()
        assert record is not None
        assert record["t"] == "2026-08-15T18:38:45+02:00"

    def test_a_bool_weight_in_the_record_is_not_a_weight(
        self, phone: FakeWeightModule
    ) -> None:
        write_raw_record({"v": 2, "b": 2000, "t": "2026-08-15", "w": True})
        assert _lines_after(phone, FakeWeight("2026-09-17", 72.4))
        assert budget_weight() == 72.4

    def test_skips_when_nothing_is_published(self, phone: FakeWeightModule) -> None:
        _seed(78.5, "2026-08-15T18:38:45+02:00")
        assert _lines_after(phone, None) == []
        assert budget_weight() == 78.5

    def test_skips_when_there_is_no_budget(self, phone: FakeWeightModule) -> None:
        assert _lines_after(phone, FakeWeight("2026-09-17", 72.4)) == []
        assert read_raw_record() is None

    def test_without_wake_alarm_installed_does_nothing(self) -> None:
        _seed(78.5, "2026-08-15T18:38:45+02:00")
        lines: list[str] = []
        with patch.dict(sys.modules, {"wake_alarm._weight": None}):
            refresh_weight_from_phone(lines.append)
        assert lines == []
        assert budget_weight() == 78.5
