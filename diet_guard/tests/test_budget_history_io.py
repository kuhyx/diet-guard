"""Tests for _budget_history.py — the effective-from budget history.

The history file is redirected into ``tmp_path`` by the autouse conftest
fixture, so every read/write here is isolated from real user data.
"""

from __future__ import annotations

from datetime import UTC, datetime
import json

from diet_guard import _budget, _budget_derived, _budget_history
from diet_guard._budget_history import (
    EPOCH_DAY,
    BudgetEntry,
    history_from_json,
    history_to_json,
    load_entries,
    read_raw_history,
    record_budget_change,
    write_raw_history,
)


def _entry(day: str, kcal: int, t: str = "2026-01-01T00:00:00+00:00") -> BudgetEntry:
    return BudgetEntry(effective_from=day, kcal=kcal, edited_at=t)


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
        today = datetime.now(tz=UTC).astimezone().date().isoformat()
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
                datetime.now(tz=UTC).astimezone().date().isoformat(),
            )
            == 2000
        )

    def test_current_budget_still_reads_back_as_the_new_value(self) -> None:
        _budget.write_budget(2000)
        assert _budget.daily_budget() == 2000

    def test_weight_is_preserved_alongside_the_history(self) -> None:
        _budget.write_budget(2000, weight_kg=78.5)
        assert _budget_derived.budget_weight() == 78.5
        assert load_entries()[-1].kcal == 2000

    def test_a_fresh_install_seeds_no_phantom_history(self) -> None:
        """With no prior budget there is nothing to grandfather."""
        _budget.write_budget(2000)
        entries = load_entries()
        assert [e.effective_from for e in entries] == [
            datetime.now(tz=UTC).astimezone().date().isoformat(),
        ]

    def test_the_history_file_is_plain_readable_json(self) -> None:
        _budget.write_budget(2000)
        document = json.loads(
            _budget_history.BUDGET_HISTORY_FILE.read_text(encoding="utf-8"),
        )
        assert document["v"] == 1
        assert isinstance(document["e"], dict)
