"""Tests for _budget_history.py — the effective-from budget history.

The history file is redirected into ``tmp_path`` by the autouse conftest
fixture, so every read/write here is isolated from real user data.
"""

from __future__ import annotations

from datetime import datetime, timezone
import json

from diet_guard import _budget, _budget_history
from diet_guard._budget_history import (
    EPOCH_DAY,
    BudgetEntry,
    BudgetSchedule,
    history_from_json,
    history_to_json,
    load_entries,
    read_raw_history,
    record_budget_change,
    seed_from_budget,
    upsert,
    write_raw_history,
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


class TestFileIO:
    """Reading, writing, and lazily seeding the history file."""

    def test_absent_file_reads_as_none(self) -> None:
        assert read_raw_history() is None

    def test_write_then_read_round_trips(self) -> None:
        write_raw_history(history_to_json((_entry(EPOCH_DAY, 2200),)))
        assert history_from_json(read_raw_history())[0].kcal == 2200

    def test_corrupt_file_reads_as_none(self) -> None:
        _budget_history.BUDGET_HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
        _budget_history.BUDGET_HISTORY_FILE.write_text("not json{{{")
        assert read_raw_history() is None

    def test_non_object_file_reads_as_none(self) -> None:
        _budget_history.BUDGET_HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
        _budget_history.BUDGET_HISTORY_FILE.write_text("[1, 2, 3]")
        assert read_raw_history() is None

    def test_load_entries_is_a_pure_read_and_never_seeds(self) -> None:
        """Seeding belongs to ``_budget``; this must not reach back into it."""
        _budget.write_raw_record({"v": 2, "b": 2200, "t": "2026-07-13T21:15:09+02:00"})
        assert load_entries() == ()
        assert read_raw_history() is None

    def test_load_entries_is_empty_without_a_budget(self) -> None:
        assert load_entries() == ()

    def test_seeding_never_overwrites_a_pulled_history(self) -> None:
        write_raw_history(history_to_json((_entry("2026-07-26", 2000),)))
        _budget.write_raw_record({"v": 2, "b": 2200, "t": "2026-07-13T21:15:09+02:00"})
        schedule = _budget.current_schedule(default=1)
        assert [e.effective_from for e in schedule.entries] == ["2026-07-26"]

    def test_record_budget_change_defaults_to_now(self) -> None:
        record_budget_change(1900)
        entries = load_entries()
        today = datetime.now(tz=timezone.utc).astimezone().date().isoformat()
        assert entries[-1].effective_from == today
        assert entries[-1].kcal == 1900


class TestEmptyHistoryDocument:
    """An empty-but-present history must still seed.

    Regression guard: the seed used to be gated on the *file* being absent,
    so an empty ``{"v": 1, "e": {}}`` -- which ``_sync`` could write back
    after merging with a pre-feature peer -- permanently disabled seeding and
    every past day silently adopted the newest budget.
    """

    def test_empty_document_still_grandfathers_on_write(self) -> None:
        _budget.write_raw_record({"v": 2, "b": 2200, "t": "2026-07-13T21:15:09+02:00"})
        write_raw_history({"v": 1, "e": {}})

        _budget.write_budget(2000)

        schedule = _budget.current_schedule(default=1)
        assert schedule.for_day("2026-06-01") == 2200

    def test_empty_document_still_grandfathers_on_read(self) -> None:
        _budget.write_raw_record({"v": 2, "b": 2200, "t": "2026-07-13T21:15:09+02:00"})
        write_raw_history({"v": 1, "e": {}})

        assert _budget.current_schedule(default=1).for_day("2026-06-01") == 2200

    def test_current_schedule_seeds_a_missing_history(self) -> None:
        _budget.write_raw_record({"v": 2, "b": 2200, "t": "2026-07-13T21:15:09+02:00"})

        assert _budget.current_schedule(default=1).for_day("2026-06-01") == 2200
        assert read_raw_history() is not None

    def test_current_schedule_without_a_budget_uses_the_default(self) -> None:
        assert _budget.current_schedule(default=1900).for_day("2026-06-01") == 1900


class TestWriteBudgetIntegration:
    """write_budget is the funnel that keeps the history correct."""

    def test_first_write_grandfathers_the_previous_value(self) -> None:
        """The load-bearing ordering test.

        A today-only assertion passes even when the seed happens *after* the
        upsert; this asserts a PAST day, which is the case that breaks if the
        two are ever reordered.
        """
        _budget.write_raw_record({"v": 2, "b": 2200, "t": "2026-07-13T21:15:09+02:00"})

        _budget.write_budget(2000)

        schedule = _budget.current_schedule(default=1)
        assert schedule.for_day("2026-06-01") == 2200
        assert (
            schedule.for_day(
                datetime.now(tz=timezone.utc).astimezone().date().isoformat(),
            )
            == 2000
        )

    def test_current_budget_still_reads_back_as_the_new_value(self) -> None:
        _budget.write_budget(2000)
        assert _budget.daily_budget() == 2000

    def test_weight_is_preserved_alongside_the_history(self) -> None:
        _budget.write_budget(2000, weight_kg=78.5)
        assert _budget.budget_weight() == 78.5
        assert load_entries()[-1].kcal == 2000

    def test_a_fresh_install_seeds_no_phantom_history(self) -> None:
        """With no prior budget there is nothing to grandfather."""
        _budget.write_budget(2000)
        entries = load_entries()
        assert [e.effective_from for e in entries] == [
            datetime.now(tz=timezone.utc).astimezone().date().isoformat(),
        ]

    def test_the_history_file_is_plain_readable_json(self) -> None:
        _budget.write_budget(2000)
        document = json.loads(
            _budget_history.BUDGET_HISTORY_FILE.read_text(encoding="utf-8"),
        )
        assert document["v"] == 1
        assert isinstance(document["e"], dict)
