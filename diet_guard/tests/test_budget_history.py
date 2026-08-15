"""Tests for _budget_history.py — the effective-from budget history.

The history file is redirected into ``tmp_path`` by the autouse conftest
fixture, so every read/write here is isolated from real user data.
"""

from __future__ import annotations

from datetime import datetime

from diet_guard._budget_history import (
    EPOCH_DAY,
    BudgetEntry,
    BudgetSchedule,
    history_from_json,
    history_to_json,
    seed_from_budget,
    upsert,
)


def _at(iso: str) -> datetime:
    return datetime.fromisoformat(iso)


def _entry(day: str, kcal: int, t: str = "2026-01-01T00:00:00+00:00") -> BudgetEntry:
    return BudgetEntry(effective_from=day, kcal=kcal, edited_at=t)


class TestForDay:
    """Resolving a day to the budget that applied on it."""

    def test_empty_history_falls_back_to_the_default(self) -> None:
        assert BudgetSchedule((), default=2200).for_day("2026-06-01") == 2200

    def test_day_before_every_entry_falls_back_to_the_default(self) -> None:
        schedule = BudgetSchedule((_entry("2026-07-26", 2000),), default=2200)
        assert schedule.for_day("2026-06-01") == 2200

    def test_exact_effective_from_day_uses_the_new_value(self) -> None:
        schedule = BudgetSchedule((_entry("2026-07-26", 2000),), default=2200)
        assert schedule.for_day("2026-07-26") == 2000

    def test_day_after_uses_the_new_value(self) -> None:
        schedule = BudgetSchedule((_entry("2026-07-26", 2000),), default=2200)
        assert schedule.for_day("2026-07-27") == 2000

    def test_between_entries_uses_the_earlier_one(self) -> None:
        schedule = BudgetSchedule(
            (_entry(EPOCH_DAY, 2200), _entry("2026-07-26", 2000)),
            default=1,
        )
        assert schedule.for_day("2026-07-25") == 2200
        assert schedule.for_day("2026-07-26") == 2000

    def test_picks_the_latest_of_several_changes(self) -> None:
        schedule = BudgetSchedule(
            (
                _entry(EPOCH_DAY, 2400),
                _entry("2026-03-01", 2200),
                _entry("2026-07-26", 2000),
            ),
            default=1,
        )
        assert schedule.for_day("2026-02-28") == 2400
        assert schedule.for_day("2026-05-05") == 2200
        assert schedule.for_day("2026-12-31") == 2000


class TestParsing:
    """history_from_json tolerates anything it is handed."""

    def test_round_trips_entries(self) -> None:
        entries = (_entry(EPOCH_DAY, 2200), _entry("2026-07-26", 2000))
        assert history_from_json(history_to_json(entries)) == entries

    def test_sorts_ascending_regardless_of_stored_order(self) -> None:
        raw = {
            "v": 1,
            "e": {
                "2026-07-26": {"b": 2000, "t": "x"},
                "1970-01-01": {"b": 2200, "t": "y"},
            },
        }
        assert [e.effective_from for e in history_from_json(raw)] == [
            "1970-01-01",
            "2026-07-26",
        ]

    def test_non_dict_is_empty(self) -> None:
        assert history_from_json([1, 2, 3]) == ()

    def test_wrong_version_is_empty(self) -> None:
        assert history_from_json({"v": 99, "e": {}}) == ()

    def test_non_dict_entries_map_is_empty(self) -> None:
        assert history_from_json({"v": 1, "e": "nope"}) == ()

    def test_malformed_entry_is_skipped(self) -> None:
        raw = {
            "v": 1,
            "e": {
                "2026-07-26": "not a record",
                "2026-07-27": {"b": "not an int"},
                "2026-07-28": {"b": True},
                "2026-07-29": {"b": 2000, "t": "2026-07-29T00:00:00+00:00"},
            },
        }
        entries = history_from_json(raw)
        assert [e.effective_from for e in entries] == ["2026-07-29"]

    def test_missing_edit_time_falls_back_to_the_epoch(self) -> None:
        entries = history_from_json({"v": 1, "e": {"2026-07-26": {"b": 2000}}})
        assert entries[0].edited_at.startswith("1970-01-01")


class TestUpsert:
    """Appending and replacing entries."""

    def test_appends_a_new_day(self) -> None:
        entries = upsert(
            (_entry(EPOCH_DAY, 2200),), kcal=2000, when=_at("2026-07-26T10:00:00+02:00")
        )
        assert [e.effective_from for e in entries] == [EPOCH_DAY, "2026-07-26"]
        assert entries[-1].kcal == 2000

    def test_second_edit_the_same_day_replaces_rather_than_appends(self) -> None:
        entries = upsert((), kcal=2000, when=_at("2026-07-26T10:00:00+02:00"))
        entries = upsert(entries, kcal=1900, when=_at("2026-07-26T18:30:00+02:00"))
        assert len(entries) == 1
        assert entries[0].kcal == 1900

    def test_stamps_the_edit_time(self) -> None:
        entries = upsert((), kcal=2000, when=_at("2026-07-26T10:00:00+02:00"))
        assert entries[0].edited_at == "2026-07-26T10:00:00+02:00"


class TestSeedFromBudget:
    """Grandfathering an existing budget to the beginning of time."""

    def test_none_record_seeds_nothing(self) -> None:
        assert seed_from_budget(None) == ()

    def test_record_without_a_budget_seeds_nothing(self) -> None:
        assert seed_from_budget({"v": 2}) == ()

    def test_boolean_budget_seeds_nothing(self) -> None:
        assert seed_from_budget({"b": True}) == ()

    def test_seeds_the_epoch_day_with_the_records_own_timestamp(self) -> None:
        seeded = seed_from_budget({"b": 2200, "t": "2026-07-13T21:15:09+02:00"})
        assert seeded == (BudgetEntry(EPOCH_DAY, 2200, "2026-07-13T21:15:09+02:00"),)

    def test_missing_timestamp_falls_back_to_the_epoch(self) -> None:
        seeded = seed_from_budget({"b": 2200})
        assert seeded[0].edited_at.startswith("1970-01-01")
