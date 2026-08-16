"""Tests for the meal-schedule half of the shared ``budget`` CRDT record."""

from __future__ import annotations

import json

from crdt_sync import Log, merge_logs

from diet_guard._meal_schedule import DEFAULT_SCHEDULE, MealSchedule
from diet_guard._meal_schedule_store import ScheduleEntry
from diet_guard.sync_merge import (
    SCHEDULE_FIELD_PREFIX,
    budget_to_log,
    log_to_schedule_history,
    parse_remote_budget,
    schedule_fields,
)

_RECORD = {"v": 2, "b": 2200, "t": "2026-08-16T10:00:00+02:00"}


def _entry(day: str, schedule: MealSchedule, when: str) -> ScheduleEntry:
    """Return a schedule entry effective from ``day``."""
    return ScheduleEntry(effective_from=day, schedule=schedule, edited_at=when)


def _wire(log: Log) -> str:
    """Return the JSON one device would push for ``log``."""
    return json.dumps(
        {rid: rec.to_dict() for rid, rec in log.items()},
        indent=2,
    )


class TestScheduleFields:
    """The per-entry fields a device contributes."""

    def test_no_entries_contributes_nothing(self) -> None:
        """A device that never edited a schedule cannot outrank a peer."""
        assert schedule_fields(()) == {}

    def test_one_field_per_entry(self) -> None:
        """Each entry becomes its own ``sched:<date>`` field."""
        fields = schedule_fields(
            (_entry("2026-08-16", MealSchedule(8, 20, 5), "2026-08-16T10:00:00+02:00"),)
        )
        assert set(fields) == {f"{SCHEDULE_FIELD_PREFIX}2026-08-16"}
        value, _ = fields[f"{SCHEDULE_FIELD_PREFIX}2026-08-16"]
        assert value == {"f": 8, "l": 20, "n": 5}

    def test_hlc_is_deterministic(self) -> None:
        """Re-syncing an unchanged history is a no-op, not a fresh write."""
        entry = _entry(
            "2026-08-16", MealSchedule(8, 20, 5), "2026-08-16T10:00:00+02:00"
        )
        first = schedule_fields((entry,))[f"{SCHEDULE_FIELD_PREFIX}2026-08-16"][1]
        second = schedule_fields((entry,))[f"{SCHEDULE_FIELD_PREFIX}2026-08-16"][1]
        assert first.wall_time_ms == second.wall_time_ms

    def test_unparsable_timestamp_falls_back_to_the_epoch(self) -> None:
        """A malformed stamp still yields a clock, so the entry still merges."""
        entry = _entry("2026-08-16", MealSchedule(8, 20, 5), "not-a-timestamp")
        hlc = schedule_fields((entry,))[f"{SCHEDULE_FIELD_PREFIX}2026-08-16"][1]
        assert hlc.wall_time_ms == 0


class TestLogToScheduleHistory:
    """Extracting the history back out of a merged log."""

    def test_absent_record_yields_nothing(self) -> None:
        """No budget record at all means no schedule history."""
        assert log_to_schedule_history({}) == ()

    def test_round_trips(self) -> None:
        """What one device pushes is what the other reads back."""
        entries = (
            _entry("2026-08-16", MealSchedule(8, 20, 5), "2026-08-16T10:00:00+02:00"),
        )
        back = log_to_schedule_history(budget_to_log(_RECORD, (), entries))
        assert len(back) == 1
        assert back[0].effective_from == "2026-08-16"
        assert back[0].schedule == MealSchedule(8, 20, 5)

    def test_normalizes_a_peers_out_of_range_schedule(self) -> None:
        """A future peer cannot make this device derive different slots."""
        log = budget_to_log(_RECORD, ())
        record = log["budget"]
        hlc = next(iter(record.fields.values()))[1]
        record.fields[f"{SCHEDULE_FIELD_PREFIX}2026-08-16"] = (
            {"f": 8, "l": 20, "n": 99},
            hlc,
        )
        assert log_to_schedule_history(log)[0].schedule == MealSchedule(8, 20, 6)

    def test_skips_malformed_values(self) -> None:
        """One bad field from a peer cannot take out the whole history."""
        log = budget_to_log(_RECORD, ())
        record = log["budget"]
        hlc = next(iter(record.fields.values()))[1]
        record.fields[f"{SCHEDULE_FIELD_PREFIX}2026-01-01"] = (7, hlc)
        record.fields[f"{SCHEDULE_FIELD_PREFIX}2026-02-01"] = ({"f": "8"}, hlc)
        record.fields[f"{SCHEDULE_FIELD_PREFIX}2026-03-01"] = (
            {"f": True, "l": 20, "n": 4},
            hlc,
        )
        assert log_to_schedule_history(log) == ()


class TestCrossDeviceMerge:
    """The property that makes this shippable without a coordinated release."""

    def test_a_pre_feature_peer_relays_the_schedule_untouched(self) -> None:
        """A device that knows nothing about schedules cannot drop them.

        ``merge_record`` is per-field LWW over the *union* of field names, and
        both devices push the merged record, so the peer's budget-only push
        merges the fields in rather than clobbering them.
        """
        entries = (
            _entry("1970-01-01", DEFAULT_SCHEDULE, "1970-01-01T00:00:00+00:00"),
            _entry("2026-08-16", MealSchedule(8, 20, 5), "2026-08-16T10:00:00+02:00"),
        )
        ours = budget_to_log(_RECORD, (), entries)
        peer = budget_to_log(
            {"v": 2, "b": 1900, "t": "2026-08-16T11:00:00+02:00"}, (), ()
        )

        merged = merge_logs(parse_remote_budget(_wire(ours)), peer)
        back = log_to_schedule_history(merged)

        assert [entry.schedule for entry in back] == [
            DEFAULT_SCHEDULE,
            MealSchedule(8, 20, 5),
        ]

    def test_the_newer_edit_wins_per_day(self) -> None:
        """Two devices editing the same day converge on the later edit."""
        older = budget_to_log(
            _RECORD,
            (),
            (
                _entry(
                    "2026-08-16", MealSchedule(8, 20, 5), "2026-08-16T10:00:00+02:00"
                ),
            ),
        )
        newer = budget_to_log(
            _RECORD,
            (),
            (
                _entry(
                    "2026-08-16", MealSchedule(7, 21, 3), "2026-08-16T18:00:00+02:00"
                ),
            ),
        )

        merged = merge_logs(parse_remote_budget(_wire(older)), newer)
        assert log_to_schedule_history(merged)[0].schedule == MealSchedule(7, 21, 3)
