"""Tests for diet_guard's entry <-> crdt_sync.Record adapters.

``TestUnionById`` through ``TestAlgebraicProperties`` are the exact same
behavioral assertions the pre-migration ``_sync_merge.merge_logs`` had --
routed through ``daylog_to_log -> crdt_sync.merge_logs -> log_to_daylog``
instead, to prove the migration preserves diet_guard's merge semantics
exactly, not just "some CRDT library now does something similar."
"""

from __future__ import annotations

import json

from crdt_sync import Record, merge_logs
import pytest

from diet_guard._sync_merge import (
    _budget_hlc,
    _entry_hlc,
    _legacy_entry_id,
    budget_to_log,
    daylog_to_log,
    entry_to_record,
    log_to_budget,
    log_to_daylog,
    parse_remote_budget,
    parse_remote_log,
    record_to_entry,
)


def _entry(**overrides: object) -> dict[str, object]:
    """Build a minimal valid entry, overriding only what a test cares about."""
    entry: dict[str, object] = {
        "id": "id-1",
        "time": "2026-06-22T08:00:00+02:00",
        "desc": "oatmeal",
        "kcal": 300.0,
        "protein_g": 10.0,
        "carbs_g": 50.0,
        "fat_g": 5.0,
        "grams": 200.0,
        "source": "manual",
    }
    entry.update(overrides)
    return entry


def _merge_daylogs(a: dict, b: dict) -> dict:
    """Merge two DayLogs through the new crdt_sync-backed pipeline."""
    return log_to_daylog(merge_logs(daylog_to_log(a), daylog_to_log(b)))


class TestUnionById:
    def test_disjoint_logs_union_into_one(self) -> None:
        a = {"2026-06-22": [_entry(id="a", time="2026-06-22T08:00:00+02:00")]}
        b = {"2026-06-22": [_entry(id="b", time="2026-06-22T12:00:00+02:00")]}
        merged = _merge_daylogs(a, b)
        assert {e["id"] for e in merged["2026-06-22"]} == {"a", "b"}

    def test_same_id_in_both_logs_is_not_duplicated(self) -> None:
        shared = _entry(id="shared")
        merged = _merge_daylogs({"2026-06-22": [shared]}, {"2026-06-22": [shared]})
        assert len(merged["2026-06-22"]) == 1

    def test_legacy_entries_without_id_dedup_by_time_and_desc(self) -> None:
        legacy_a = _entry(id=None, time="2026-06-20T08:00:00+02:00", desc="toast")
        legacy_a.pop("id")
        legacy_b = dict(legacy_a)
        merged = _merge_daylogs({"2026-06-20": [legacy_a]}, {"2026-06-20": [legacy_b]})
        assert len(merged["2026-06-20"]) == 1

    def test_legacy_and_id_entries_with_different_keys_both_survive(self) -> None:
        legacy = _entry(time="2026-06-20T08:00:00+02:00", desc="toast")
        legacy.pop("id")
        with_id = _entry(id="x", time="2026-06-20T09:00:00+02:00", desc="eggs")
        merged = _merge_daylogs({"2026-06-20": [legacy]}, {"2026-06-20": [with_id]})
        assert len(merged["2026-06-20"]) == 2


class TestTombstoneWins:
    def test_tombstone_beats_a_non_deleted_copy_either_order(self) -> None:
        normal = _entry(id="x", deleted=False)
        tombstoned = _entry(id="x", deleted=True)

        forward = _merge_daylogs(
            {"2026-06-22": [normal]},
            {"2026-06-22": [tombstoned]},
        )
        backward = _merge_daylogs(
            {"2026-06-22": [tombstoned]},
            {"2026-06-22": [normal]},
        )

        assert forward["2026-06-22"][0]["deleted"] is True
        assert backward["2026-06-22"][0]["deleted"] is True

    def test_two_tombstoned_copies_stay_tombstoned(self) -> None:
        tombstoned = _entry(id="x", deleted=True)
        merged = _merge_daylogs(
            {"2026-06-22": [tombstoned]},
            {"2026-06-22": [dict(tombstoned)]},
        )
        assert merged["2026-06-22"][0]["deleted"] is True


class TestRebucketingAndOrdering:
    def test_entry_is_filed_under_its_own_times_date_not_the_arrival_bucket(
        self,
    ) -> None:
        misfiled = _entry(id="x", time="2026-06-21T23:00:00+02:00")
        merged = _merge_daylogs({"2026-06-22": [misfiled]}, {})
        assert merged == {"2026-06-21": [misfiled]}

    def test_a_days_entries_are_sorted_oldest_first(self) -> None:
        late = _entry(id="late", time="2026-06-22T20:00:00+02:00")
        early = _entry(id="early", time="2026-06-22T08:00:00+02:00")
        merged = _merge_daylogs({"2026-06-22": [late]}, {"2026-06-22": [early]})
        assert [e["id"] for e in merged["2026-06-22"]] == ["early", "late"]


class TestAlgebraicProperties:
    def test_merge_is_commutative(self) -> None:
        a = {"2026-06-22": [_entry(id="a")]}
        b = {"2026-06-22": [_entry(id="b", time="2026-06-22T09:00:00+02:00")]}
        assert _merge_daylogs(a, b) == _merge_daylogs(b, a)

    def test_merge_is_idempotent(self) -> None:
        canonical = {"2026-06-22": [_entry(id="a")]}
        assert _merge_daylogs(canonical, canonical) == canonical

    def test_merging_with_an_empty_log_is_a_no_op(self) -> None:
        log = {"2026-06-22": [_entry(id="a")]}
        assert _merge_daylogs(log, {}) == log
        assert _merge_daylogs({}, log) == log

    def test_merging_two_empty_logs_is_empty(self) -> None:
        assert _merge_daylogs({}, {}) == {}


class TestEntryHlc:
    def test_same_entry_always_yields_the_same_hlc(self) -> None:
        entry = _entry()
        assert _entry_hlc(entry) == _entry_hlc(dict(entry))

    def test_malformed_time_still_yields_a_valid_hlc(self) -> None:
        entry = _entry(time="not-a-timestamp")
        assert _entry_hlc(entry).wall_time_ms == 0

    def test_missing_time_still_yields_a_valid_hlc(self) -> None:
        entry = _entry()
        del entry["time"]
        assert _entry_hlc(entry).wall_time_ms == 0


class TestLegacyEntryId:
    def test_same_time_and_desc_yields_the_same_id(self) -> None:
        a = _entry(time="2026-06-20T08:00:00+02:00", desc="toast")
        b = _entry(time="2026-06-20T08:00:00+02:00", desc="toast", kcal=999.0)
        assert _legacy_entry_id(a) == _legacy_entry_id(b)

    def test_different_desc_yields_a_different_id(self) -> None:
        a = _entry(time="2026-06-20T08:00:00+02:00", desc="toast")
        b = _entry(time="2026-06-20T08:00:00+02:00", desc="eggs")
        assert _legacy_entry_id(a) != _legacy_entry_id(b)


class TestEntryRecordRoundTrip:
    def test_round_trip_preserves_all_fields(self) -> None:
        entry = _entry(id="x")
        assert record_to_entry(entry_to_record(entry)) == entry

    def test_round_trip_of_a_deleted_entry_preserves_the_tombstone(self) -> None:
        entry = _entry(id="x", deleted=True)
        assert record_to_entry(entry_to_record(entry))["deleted"] is True

    def test_legacy_entry_gets_a_derived_id_on_round_trip(self) -> None:
        entry = _entry(time="2026-06-20T08:00:00+02:00", desc="toast")
        entry.pop("id")
        round_tripped = record_to_entry(entry_to_record(entry))
        assert round_tripped["id"] == _legacy_entry_id(entry)


class TestParseRemoteLog:
    def test_parses_new_format_wire_content(self) -> None:
        entry = _entry(id="x")
        pushed = {"x": entry_to_record(entry).to_dict()}
        log = parse_remote_log(_dumps(pushed))
        assert log["x"].id == "x"

    def test_parses_old_daylog_format_for_backward_compatibility(self) -> None:
        entry = _entry(id="x")
        old_format = {"2026-06-22": [entry]}
        log = parse_remote_log(_dumps(old_format))
        assert log["x"].id == "x"

    def test_empty_object_parses_as_empty_log(self) -> None:
        assert parse_remote_log("{}") == {}

    def test_non_object_top_level_raises_type_error(self) -> None:
        with pytest.raises(TypeError):
            parse_remote_log("[1, 2, 3]")

    def test_old_format_day_not_a_list_raises_type_error(self) -> None:
        with pytest.raises(TypeError):
            parse_remote_log(_dumps({"2026-06-22": "not-a-list"}))

    def test_old_format_entry_not_an_object_raises_type_error(self) -> None:
        with pytest.raises(TypeError):
            parse_remote_log(_dumps({"2026-06-22": ["not-a-dict"]}))

    def test_invalid_json_raises(self) -> None:
        with pytest.raises(json.JSONDecodeError):
            parse_remote_log("not json{{{")


def _budget_record(**overrides: object) -> dict[str, object]:
    """Build a minimal valid raw budget record, overriding what a test needs."""
    record: dict[str, object] = {
        "v": 2,
        "b": 2000,
        "t": "2026-06-22T08:00:00+02:00",
    }
    record.update(overrides)
    return record


class TestBudgetHlc:
    def test_same_record_always_yields_the_same_hlc(self) -> None:
        record = _budget_record()
        assert _budget_hlc(record) == _budget_hlc(dict(record))

    def test_malformed_t_still_yields_a_valid_hlc(self) -> None:
        record = _budget_record(t="not-a-timestamp")
        assert _budget_hlc(record).wall_time_ms == 0

    def test_a_later_t_yields_a_greater_hlc(self) -> None:
        earlier = _budget_record(t="2020-01-01T00:00:00+00:00")
        later = _budget_record(t="2030-01-01T00:00:00+00:00")
        assert _budget_hlc(later) > _budget_hlc(earlier)


class TestBudgetLogRoundTrip:
    def test_none_record_yields_an_empty_log(self) -> None:
        assert budget_to_log(None) == {}

    def test_round_trip_preserves_the_budget_and_weight(self) -> None:
        record = _budget_record(w=80.0)
        round_tripped = log_to_budget(budget_to_log(record))
        assert round_tripped is not None
        assert round_tripped["b"] == 2000
        assert round_tripped["w"] == 80.0

    def test_round_tripped_t_reflects_the_winning_hlc(self) -> None:
        record = _budget_record(t="2026-06-22T08:00:00+02:00")
        round_tripped = log_to_budget(budget_to_log(record))
        assert round_tripped is not None
        assert round_tripped["t"] != ""

    def test_empty_log_has_no_budget(self) -> None:
        assert log_to_budget({}) is None

    def test_record_with_no_value_field_has_no_hlc_in_result(self) -> None:
        """A record present but missing the "value" field is a defensive
        edge case (should not occur from budget_to_log itself) -- the
        result still comes back without crashing, and with no ``t``.
        """
        log = {"budget": Record(id="budget", fields={})}
        round_tripped = log_to_budget(log)
        assert round_tripped == {}


class TestParseRemoteBudget:
    def test_parses_pushed_budget_wire_content(self) -> None:
        record = _budget_record()
        pushed = budget_to_log(record)
        wire = json.dumps({rid: rec.to_dict() for rid, rec in pushed.items()})
        log = parse_remote_budget(wire)
        assert log["budget"].id == "budget"

    def test_empty_object_parses_as_empty_log(self) -> None:
        assert parse_remote_budget("{}") == {}

    def test_non_object_top_level_raises_type_error(self) -> None:
        with pytest.raises(TypeError):
            parse_remote_budget("[1, 2, 3]")

    def test_invalid_json_raises(self) -> None:
        with pytest.raises(json.JSONDecodeError):
            parse_remote_budget("not json{{{")


def _dumps(data: object) -> str:
    return json.dumps(data)
