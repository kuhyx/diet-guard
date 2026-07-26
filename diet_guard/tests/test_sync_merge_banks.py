"""Tests for the food-bank Record adapters.

Split out of ``test_sync_merge.py`` to keep both files under the repo's
500-line ceiling. The derived bank clocks on ``count`` (so last-writer-wins
means max-count-wins); the curated bank clocks on an edit stamp.
"""

from __future__ import annotations

import json

from crdt_sync import Record, merge_logs
import pytest

from diet_guard._sync_merge import (
    _budget_hlc,
    food_bank_to_log,
    log_to_food_bank,
    log_to_manual_bank,
    manual_bank_to_log,
    parse_remote_food_bank,
    parse_remote_manual_bank,
)

_MANUAL_REC: dict[str, object] = {
    "desc": "Skyr",
    "kcal": 120.0,
    "count": 0,
    "t": "2026-07-26T10:00:00+02:00",
}


class TestFoodBankAdapters:
    """The log-derived food bank's max-count merge."""

    @staticmethod
    def _rec(count: float, kcal: float = 95.0) -> dict[str, object]:
        return {"desc": "Apple", "kcal": kcal, "count": count}

    def test_round_trips_a_record(self) -> None:
        back = log_to_food_bank(food_bank_to_log({"apple": self._rec(5)}))
        assert back["apple"]["count"] == 5

    def test_count_is_the_clock(self) -> None:
        log = food_bank_to_log({"apple": self._rec(5)})
        assert log["apple"].fields["body"][1].wall_time_ms == 5

    def test_a_missing_count_clocks_at_zero(self) -> None:
        log = food_bank_to_log({"apple": {"desc": "Apple"}})
        assert log["apple"].fields["body"][1].wall_time_ms == 0

    def test_the_higher_count_wins(self) -> None:
        """A device that has replayed more of the log knows the truer count."""
        behind = food_bank_to_log({"apple": self._rec(3, kcal=90)})
        ahead = food_bank_to_log({"apple": self._rec(9, kcal=95)})
        merged = log_to_food_bank(merge_logs(behind, ahead))
        assert merged["apple"]["count"] == 9
        assert merged["apple"]["kcal"] == 95

    def test_the_merge_is_order_independent(self) -> None:
        a = food_bank_to_log({"apple": self._rec(3)})
        b = food_bank_to_log({"apple": self._rec(9)})
        assert log_to_food_bank(merge_logs(a, b)) == log_to_food_bank(
            merge_logs(b, a),
        )

    def test_re_merging_is_idempotent(self) -> None:
        """The count only moves when the log does, so a tick is a no-op."""
        once = food_bank_to_log({"apple": self._rec(5)})
        assert log_to_food_bank(merge_logs(once, once)) == log_to_food_bank(once)

    def test_different_foods_union(self) -> None:
        a = food_bank_to_log({"apple": self._rec(1)})
        b = food_bank_to_log({"pear": self._rec(1)})
        assert set(log_to_food_bank(merge_logs(a, b))) == {"apple", "pear"}

    def test_a_non_dict_record_is_skipped(self) -> None:
        assert food_bank_to_log({"apple": "nope"}) == {}

    def test_a_non_dict_body_is_skipped_on_read(self) -> None:
        log = {"apple": Record(id="apple", fields={"body": ("x", _budget_hlc({}))})}
        assert log_to_food_bank(log) == {}

    def test_a_tombstoned_record_is_dropped_on_read(self) -> None:
        """A tombstone must not be laundered back into a live bank record."""
        log = {
            "apple": Record(
                id="apple",
                fields={"body": (self._rec(5), _budget_hlc({}))},
                deleted=True,
            ),
        }
        assert log_to_food_bank(log) == {}

    def test_parses_pushed_wire_content(self) -> None:
        pushed = food_bank_to_log({"apple": self._rec(5)})
        wire = json.dumps({rid: rec.to_dict() for rid, rec in pushed.items()})
        assert "apple" in parse_remote_food_bank(wire)

    def test_non_object_top_level_raises_type_error(self) -> None:
        with pytest.raises(TypeError):
            parse_remote_food_bank("[1, 2, 3]")

    def test_invalid_json_raises(self) -> None:
        with pytest.raises(json.JSONDecodeError):
            parse_remote_food_bank("not json{{{")


_MANUAL_REC: dict[str, object] = {
    "desc": "Skyr",
    "kcal": 120.0,
    "count": 0,
    "t": "2026-07-26T10:00:00+02:00",
}


class TestManualBankAdapters:
    """The hand-curated food bank's Record round trip."""

    def test_round_trips_a_record(self) -> None:
        back = log_to_manual_bank(manual_bank_to_log({"skyr": _MANUAL_REC}))
        assert back["skyr"]["desc"] == "Skyr"
        assert back["skyr"]["kcal"] == 120.0

    def test_edit_time_is_reconstructed_from_the_hlc(self) -> None:
        back = log_to_manual_bank(manual_bank_to_log({"skyr": _MANUAL_REC}))
        assert back["skyr"]["t"].startswith("2026-07-26T")

    def test_the_edit_stamp_does_not_travel_inside_the_body(self) -> None:
        log = manual_bank_to_log({"skyr": _MANUAL_REC})
        assert "t" not in log["skyr"].fields["body"][0]

    def test_a_missing_edit_stamp_falls_back_to_the_epoch(self) -> None:
        log = manual_bank_to_log({"skyr": {"desc": "Skyr"}})
        assert log["skyr"].fields["body"][1].wall_time_ms == 0

    def test_an_unparsable_edit_stamp_falls_back_to_the_epoch(self) -> None:
        log = manual_bank_to_log({"skyr": {"desc": "Skyr", "t": "nonsense"}})
        assert log["skyr"].fields["body"][1].wall_time_ms == 0

    def test_a_non_dict_record_is_skipped(self) -> None:
        assert manual_bank_to_log({"skyr": "not a record"}) == {}

    def test_a_non_dict_body_is_skipped_on_read(self) -> None:
        log = {"skyr": Record(id="skyr", fields={"body": ("nope", _budget_hlc({}))})}
        assert log_to_manual_bank(log) == {}

    def test_a_record_without_a_body_reads_as_an_empty_entry(self) -> None:
        """Defensive: not produced by manual_bank_to_log, but must not crash."""
        assert log_to_manual_bank({"skyr": Record(id="skyr", fields={})}) == {
            "skyr": {},
        }

    def test_a_newer_edit_wins_the_merge(self) -> None:
        older = manual_bank_to_log({"skyr": _MANUAL_REC})
        newer = manual_bank_to_log(
            {"skyr": {"desc": "Skyr", "kcal": 999.0, "t": "2999-01-01T00:00:00+02:00"}},
        )
        merged = log_to_manual_bank(merge_logs(older, newer))
        assert merged["skyr"]["kcal"] == 999.0

    def test_different_foods_union_rather_than_replace(self) -> None:
        a = manual_bank_to_log({"skyr": _MANUAL_REC})
        b = manual_bank_to_log({"kefir": {"desc": "Kefir", "t": _MANUAL_REC["t"]}})
        assert set(log_to_manual_bank(merge_logs(a, b))) == {"skyr", "kefir"}

    def test_a_tombstoned_record_is_dropped_on_read(self) -> None:
        log = {
            "skyr": Record(
                id="skyr",
                fields={"body": (dict(_MANUAL_REC), _budget_hlc({}))},
                deleted=True,
            ),
        }
        assert log_to_manual_bank(log) == {}

    def test_parses_pushed_wire_content(self) -> None:
        pushed = manual_bank_to_log({"skyr": _MANUAL_REC})
        wire = json.dumps({rid: rec.to_dict() for rid, rec in pushed.items()})
        assert "skyr" in parse_remote_manual_bank(wire)

    def test_non_object_top_level_raises_type_error(self) -> None:
        with pytest.raises(TypeError):
            parse_remote_manual_bank("[1, 2, 3]")

    def test_invalid_json_raises(self) -> None:
        with pytest.raises(json.JSONDecodeError):
            parse_remote_manual_bank("not json{{{")
