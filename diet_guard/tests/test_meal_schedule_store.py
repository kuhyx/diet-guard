"""Tests for the meal-schedule history and its on-disk form.

Mirrors ``test_budget_history*.py``: the two histories exist for the same
reason and share a shape, so a change to one usually wants the same change
here.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import TYPE_CHECKING
from unittest.mock import patch

from diet_guard import _meal_schedule_store as store
from diet_guard._meal_schedule import DEFAULT_SCHEDULE, MealSchedule

if TYPE_CHECKING:
    from pathlib import Path


def _at(day: str) -> datetime:
    """Return midnight UTC on ``day`` (``YYYY-MM-DD``)."""
    return datetime.fromisoformat(f"{day}T00:00:00+00:00")


class TestEntryJson:
    """One entry's wire/disk representation."""

    def test_round_trips(self) -> None:
        """Encoding then decoding preserves the schedule and the stamp."""
        entry = store.ScheduleEntry(
            effective_from="2026-08-16",
            schedule=MealSchedule(8, 20, 5),
            edited_at="2026-08-16T12:00:00+00:00",
        )
        assert store.entry_from_json("2026-08-16", store.entry_to_json(entry)) == entry

    def test_normalizes_on_the_way_in(self) -> None:
        """A peer's out-of-range schedule is clamped, not trusted verbatim."""
        entry = store.entry_from_json("2026-08-16", {"f": 8, "l": 20, "n": 99})
        assert entry is not None
        assert entry.schedule == MealSchedule(8, 20, 6)

    def test_missing_timestamp_falls_back_to_the_epoch(self) -> None:
        """An entry with no stamp still parses, losing only its ordering."""
        entry = store.entry_from_json("2026-08-16", {"f": 8, "l": 20, "n": 4})
        assert entry is not None
        assert entry.edited_at == "1970-01-01T00:00:00+00:00"

    def test_rejects_a_non_mapping(self) -> None:
        """A scalar where a record belongs is skipped, not raised on."""
        assert store.entry_from_json("2026-08-16", "nonsense") is None

    def test_rejects_non_integer_fields(self) -> None:
        """A malformed field skips just that entry."""
        assert store.entry_from_json("2026-08-16", {"f": "8", "l": 20, "n": 4}) is None


class TestHistoryJson:
    """The whole-document form."""

    def test_round_trips_and_sorts(self) -> None:
        """Entries come back ascending regardless of insertion order."""
        entries = (
            store.ScheduleEntry("2026-08-16", MealSchedule(8, 20, 5), "t1"),
            store.ScheduleEntry("2026-01-01", DEFAULT_SCHEDULE, "t0"),
        )
        parsed = store.history_from_json(store.history_to_json(entries))
        assert [entry.effective_from for entry in parsed] == [
            "2026-01-01",
            "2026-08-16",
        ]

    def test_unreadable_documents_yield_nothing(self) -> None:
        """Anything unusable degrades to "no history", never an exception."""
        assert store.history_from_json("nonsense") == ()
        assert store.history_from_json({"e": "nonsense"}) == ()
        assert store.history_from_json({}) == ()

    def test_skips_only_the_bad_entry(self) -> None:
        """One corrupt field from a peer cannot take out the whole history."""
        parsed = store.history_from_json(
            {"e": {"2026-01-01": {"f": 8, "l": 20, "n": 4}, "2026-02-01": 7}}
        )
        assert [entry.effective_from for entry in parsed] == ["2026-01-01"]


class TestScheduleForDay:
    """Resolving the schedule that applied on a given day."""

    def test_defaults_when_the_history_is_silent(self) -> None:
        """A day before any entry uses the default, not the newest entry."""
        entries = (store.ScheduleEntry("2026-08-16", MealSchedule(8, 20, 5), "t"),)
        assert store.schedule_for_day(entries, "2026-08-15") == DEFAULT_SCHEDULE

    def test_uses_the_newest_applicable_entry(self) -> None:
        """The latest entry effective on or before the day wins."""
        entries = (
            store.ScheduleEntry("2026-01-01", MealSchedule(8, 20, 4), "t0"),
            store.ScheduleEntry("2026-08-16", MealSchedule(8, 20, 5), "t1"),
        )
        assert store.schedule_for_day(entries, "2026-08-16") == MealSchedule(8, 20, 5)
        assert store.schedule_for_day(entries, "2026-05-01") == MealSchedule(8, 20, 4)


class TestUpsert:
    """Appending an edit to the history."""

    def test_appends_a_new_day(self) -> None:
        """An edit on a fresh day adds an entry."""
        entries = store.upsert((), MealSchedule(8, 20, 5), _at("2026-08-16"))
        assert len(entries) == 1
        assert entries[0].effective_from == "2026-08-16"

    def test_replaces_a_same_day_re_edit(self) -> None:
        """Editing twice in one day leaves one entry, not two."""
        first = store.upsert((), MealSchedule(8, 20, 5), _at("2026-08-16"))
        second = store.upsert(first, MealSchedule(9, 21, 3), _at("2026-08-16"))
        assert len(second) == 1
        assert second[0].schedule == MealSchedule(9, 21, 3)


class TestSeedDefault:
    """Grandfathering days that predate the first edit."""

    def test_pins_the_default_at_the_epoch(self) -> None:
        """Seeding makes every earlier day resolve to the old schedule."""
        seeded = store.seed_default(())
        assert seeded[0].effective_from == store.EPOCH_DAY
        assert seeded[0].schedule == DEFAULT_SCHEDULE

    def test_is_idempotent(self) -> None:
        """Seeding twice does not stack a second epoch entry."""
        assert store.seed_default(store.seed_default(())) == store.seed_default(())


class TestPersistence:
    """The on-disk file, through the conftest-redirected path."""

    def test_absent_file_reads_as_no_history(self) -> None:
        """A device that has never edited contributes nothing."""
        assert store.read_raw_history() is None
        assert store.load_entries() == ()

    def test_round_trips_through_disk(self) -> None:
        """What is written is what is read back."""
        store.record_schedule_change(MealSchedule(8, 20, 5), when=_at("2026-08-16"))
        assert store.schedule_for_day(
            store.load_entries(), "2026-08-16"
        ) == MealSchedule(8, 20, 5)

    def test_recording_grandfathers_earlier_days(self) -> None:
        """Switching to five meals leaves past days on the four-meal schedule.

        This is the whole point of the history: without the epoch seed, every
        past day would adopt the schedule chosen today and look like it had
        missed a checkpoint.
        """
        store.record_schedule_change(MealSchedule(8, 20, 5), when=_at("2026-08-16"))
        entries = store.load_entries()
        assert store.schedule_for_day(entries, "2020-01-01") == DEFAULT_SCHEDULE
        assert store.schedule_for_day(entries, "2026-08-16") == MealSchedule(8, 20, 5)

    def test_corrupt_file_degrades_to_the_default(self) -> None:
        """Unparsable JSON is treated as "no history", never a crash."""
        store.MEAL_SCHEDULE_FILE.parent.mkdir(parents=True, exist_ok=True)
        store.MEAL_SCHEDULE_FILE.write_text("{not json")
        assert store.read_raw_history() is None
        assert store.current_schedule() == DEFAULT_SCHEDULE

    def test_non_mapping_document_degrades(self) -> None:
        """A JSON array where an object belongs is ignored."""
        store.MEAL_SCHEDULE_FILE.parent.mkdir(parents=True, exist_ok=True)
        store.MEAL_SCHEDULE_FILE.write_text("[1, 2]")
        assert store.read_raw_history() is None

    def test_unreadable_file_degrades(self, tmp_path: Path) -> None:
        """An OSError on read is swallowed like a parse failure."""
        directory = tmp_path / "not-a-file"
        directory.mkdir()
        # Patched rather than assigned: a bare assignment would outlive this
        # test and silently redirect the module for everything after it.
        with patch.object(store, "MEAL_SCHEDULE_FILE", directory):
            assert store.read_raw_history() is None

    def test_current_schedule_defaults_before_any_edit(self) -> None:
        """A fresh install behaves exactly as it did before this feature."""
        assert store.current_schedule() == DEFAULT_SCHEDULE

    def test_record_defaults_to_now(self) -> None:
        """Omitting ``when`` stamps the edit with the current time."""
        store.record_schedule_change(MealSchedule(7, 19, 3))
        today = datetime.now(tz=timezone.utc).astimezone().date().isoformat()
        assert store.schedule_for_day(store.load_entries(), today) == MealSchedule(
            7, 19, 3
        )
