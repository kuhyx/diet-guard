"""Tests for the budget and budget-history adapters.

Split out of ``test_sync_merge.py`` to keep both files under the repo's
250-line cap, along the same seam as the module they cover
(``diet_guard.sync_merge._budget``).
"""

from __future__ import annotations

import json

from crdt_sync import Record, merge_logs
import pytest

from diet_guard._budget_history import BudgetEntry
from diet_guard.sync_merge import (
    _budget_hlc,
    budget_to_log,
    log_to_budget,
    log_to_history,
    parse_remote_budget,
)


def _budget_record(**overrides: object) -> dict[str, object]:
    """Build a minimal valid raw budget record, overriding what a test needs."""
    record: dict[str, object] = {
        "v": 2,
        "b": 2000,
        "t": "2026-06-22T08:00:00+02:00",
    }
    record.update(overrides)
    return record


_HIST_SEED = BudgetEntry("1970-01-01", 2200, "2026-07-13T21:15:09+02:00")
_HIST_CUT = BudgetEntry("2026-07-26", 2000, "2026-07-26T10:00:00+02:00")


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

    def test_round_trip_preserves_the_budget(self) -> None:
        record = _budget_record()
        round_tripped = log_to_budget(budget_to_log(record))
        assert round_tripped is not None
        assert round_tripped["b"] == 2000

    def test_weight_travels_as_its_own_field(self) -> None:
        """``w`` is shared state, carried as a field of its own.

        Inside ``value`` it was collateral damage of whole-map LWW: the phone
        rebuilds that map without ``w``, so any phone budget edit silently
        deleted the stored weight and the protein target with it.
        """
        log = budget_to_log(_budget_record(w=80.0))
        assert "w" not in log["budget"].fields["value"][0]
        assert log["budget"].fields["weight"][0] == 80.0

    def test_weight_round_trips(self) -> None:
        round_tripped = log_to_budget(budget_to_log(_budget_record(w=80.0)))
        assert round_tripped is not None
        assert round_tripped["w"] == 80.0

    def test_no_weight_round_trips_to_no_weight(self) -> None:
        round_tripped = log_to_budget(budget_to_log(_budget_record()))
        assert round_tripped is not None
        assert "w" not in round_tripped

    def test_a_non_numeric_weight_is_not_emitted(self) -> None:
        assert "weight" not in budget_to_log(_budget_record(w="heavy"))["budget"].fields

    def test_a_boolean_weight_is_not_emitted(self) -> None:
        assert "weight" not in budget_to_log(_budget_record(w=True))["budget"].fields

    def test_a_non_numeric_weight_field_is_ignored_on_read(self) -> None:
        log = {
            "budget": Record(
                id="budget",
                fields={"weight": ("heavy", _budget_hlc({}))},
            ),
        }
        assert "w" not in (log_to_budget(log) or {})

    def test_a_weightless_peer_cannot_delete_the_weight(self) -> None:
        """The whole point: the phone never sets ``w`` and must not drop it."""
        ours = budget_to_log(_budget_record(w=80.0))
        phone = budget_to_log(
            {"v": 2, "b": 1800, "t": "2099-01-01T00:00:00+00:00"},
        )
        merged = log_to_budget(merge_logs(ours, phone))
        assert merged is not None
        assert merged["b"] == 1800
        assert merged["w"] == 80.0

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


class TestBudgetHistoryFields:
    """The effective-from history riding along on the budget record."""

    def test_history_becomes_one_field_per_date(self) -> None:
        log = budget_to_log(_budget_record(), (_HIST_SEED, _HIST_CUT))
        fields = log["budget"].fields
        assert "value" in fields
        assert fields["hist:1970-01-01"][0] == 2200
        assert fields["hist:2026-07-26"][0] == 2000

    def test_round_trips_back_to_entries(self) -> None:
        entries = log_to_history(
            budget_to_log(_budget_record(), (_HIST_SEED, _HIST_CUT))
        )
        assert [e.effective_from for e in entries] == ["1970-01-01", "2026-07-26"]
        assert [e.kcal for e in entries] == [2200, 2000]

    def test_no_history_round_trips_to_nothing(self) -> None:
        assert log_to_history(budget_to_log(_budget_record())) == ()

    def test_empty_log_has_no_history(self) -> None:
        assert log_to_history({}) == ()

    def test_non_history_fields_are_ignored(self) -> None:
        log = {
            "budget": Record(
                id="budget", fields={"value": ({"b": 2000}, _budget_hlc({}))}
            )
        }
        assert log_to_history(log) == ()

    def test_non_int_history_value_is_skipped(self) -> None:
        log = {
            "budget": Record(
                id="budget",
                fields={"hist:2026-07-26": ("nonsense", _budget_hlc({}))},
            ),
        }
        assert log_to_history(log) == ()

    def test_unparsable_edit_time_still_yields_a_field(self) -> None:
        broken = BudgetEntry("2026-07-26", 2000, "not a timestamp")
        log = budget_to_log(_budget_record(), (broken,))
        assert "hist:2026-07-26" in log["budget"].fields

    def test_history_survives_a_merge_with_a_history_free_peer(self) -> None:
        """The rollout guarantee: an old device cannot clobber the history.

        merge_record is per-field LWW over the *union* of field names, so a
        peer that only pushes ``value`` leaves ``hist:*`` untouched -- which
        is why this needed no coordinated release.
        """
        ours = budget_to_log(_budget_record(), (_HIST_SEED, _HIST_CUT))
        legacy = {
            "budget": Record(
                id="budget",
                fields={
                    "value": (
                        {"v": 2, "b": 2200},
                        _budget_hlc({"t": "2099-01-01T00:00:00+00:00"}),
                    )
                },
            ),
        }
        merged = merge_logs(ours, legacy)
        assert len(log_to_history(merged)) == 2


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
