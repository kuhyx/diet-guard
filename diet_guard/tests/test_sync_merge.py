"""Tests for the pure cross-device log-merge logic."""

from __future__ import annotations

from diet_guard._sync_merge import merge_logs


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


class TestUnionById:
    def test_disjoint_logs_union_into_one(self) -> None:
        a = {"2026-06-22": [_entry(id="a", time="2026-06-22T08:00:00+02:00")]}
        b = {"2026-06-22": [_entry(id="b", time="2026-06-22T12:00:00+02:00")]}
        merged = merge_logs(a, b)
        assert {e["id"] for e in merged["2026-06-22"]} == {"a", "b"}

    def test_same_id_in_both_logs_is_not_duplicated(self) -> None:
        shared = _entry(id="shared")
        merged = merge_logs({"2026-06-22": [shared]}, {"2026-06-22": [shared]})
        assert len(merged["2026-06-22"]) == 1

    def test_legacy_entries_without_id_dedup_by_time_and_desc(self) -> None:
        legacy_a = _entry(id=None, time="2026-06-20T08:00:00+02:00", desc="toast")
        legacy_a.pop("id")
        legacy_b = dict(legacy_a)
        merged = merge_logs({"2026-06-20": [legacy_a]}, {"2026-06-20": [legacy_b]})
        assert len(merged["2026-06-20"]) == 1

    def test_legacy_and_id_entries_with_different_keys_both_survive(self) -> None:
        legacy = _entry(time="2026-06-20T08:00:00+02:00", desc="toast")
        legacy.pop("id")
        with_id = _entry(id="x", time="2026-06-20T09:00:00+02:00", desc="eggs")
        merged = merge_logs({"2026-06-20": [legacy]}, {"2026-06-20": [with_id]})
        assert len(merged["2026-06-20"]) == 2


class TestTombstoneWins:
    def test_tombstone_beats_a_non_deleted_copy_either_order(self) -> None:
        normal = _entry(id="x", deleted=False)
        tombstoned = _entry(id="x", deleted=True)

        forward = merge_logs(
            {"2026-06-22": [normal]},
            {"2026-06-22": [tombstoned]},
        )
        backward = merge_logs(
            {"2026-06-22": [tombstoned]},
            {"2026-06-22": [normal]},
        )

        assert forward["2026-06-22"][0]["deleted"] is True
        assert backward["2026-06-22"][0]["deleted"] is True

    def test_two_tombstoned_copies_stay_tombstoned(self) -> None:
        tombstoned = _entry(id="x", deleted=True)
        merged = merge_logs(
            {"2026-06-22": [tombstoned]},
            {"2026-06-22": [dict(tombstoned)]},
        )
        assert merged["2026-06-22"][0]["deleted"] is True


class TestRebucketingAndOrdering:
    def test_entry_is_filed_under_its_own_times_date_not_the_arrival_bucket(
        self,
    ) -> None:
        misfiled = _entry(id="x", time="2026-06-21T23:00:00+02:00")
        merged = merge_logs({"2026-06-22": [misfiled]}, {})
        assert merged == {"2026-06-21": [misfiled]}

    def test_a_days_entries_are_sorted_oldest_first(self) -> None:
        late = _entry(id="late", time="2026-06-22T20:00:00+02:00")
        early = _entry(id="early", time="2026-06-22T08:00:00+02:00")
        merged = merge_logs({"2026-06-22": [late]}, {"2026-06-22": [early]})
        assert [e["id"] for e in merged["2026-06-22"]] == ["early", "late"]


class TestAlgebraicProperties:
    def test_merge_is_commutative(self) -> None:
        a = {"2026-06-22": [_entry(id="a")]}
        b = {"2026-06-22": [_entry(id="b", time="2026-06-22T09:00:00+02:00")]}
        assert merge_logs(a, b) == merge_logs(b, a)

    def test_merge_is_idempotent(self) -> None:
        canonical = {"2026-06-22": [_entry(id="a")]}
        assert merge_logs(canonical, canonical) == canonical

    def test_merging_with_an_empty_log_is_a_no_op(self) -> None:
        log = {"2026-06-22": [_entry(id="a")]}
        assert merge_logs(log, {}) == log
        assert merge_logs({}, log) == log

    def test_merging_two_empty_logs_is_empty(self) -> None:
        assert merge_logs({}, {}) == {}
