"""Slot choice and the idempotent write of one Claude meal."""

from __future__ import annotations

from datetime import UTC, datetime
from unittest.mock import patch

from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from diet_guard._claude_contract import MealRequest, Mode, entry_id_for
from diet_guard._claude_log import already_logged, log_estimate, resolve_slot
from diet_guard._claude_schema import Estimate
from diet_guard._slot_wire import entry_slot_minute
from diet_guard._state import load_log

EST = Estimate("2 jajka", 190.0, 410.0, 17.5, 22.0, 26.0, None)
NOON = datetime(2026, 11, 17, 12, 30, tzinfo=UTC)


def _request(mode: Mode = "due", slot: int = 480, text: str = "x") -> MealRequest:
    return MealRequest(text, None, slot, mode)


def test_due_mode_takes_the_oldest_due_slot_and_ignores_the_hint() -> None:
    """Two slots due: the older one, whatever the phone says."""
    with patch("diet_guard._claude_log.due_slots", return_value=(480, 720)):
        assert resolve_slot(_request("due", slot=1200), NOON) == 480


def test_due_mode_with_nothing_due_falls_back_to_slot_for_log() -> None:
    """Nothing due is not an error: the ordinary now-rule decides."""
    with patch("diet_guard._claude_log.due_slots", return_value=()):
        assert resolve_slot(_request("due", slot=1200), NOON) == 720


def test_normal_mode_snaps_the_hint_to_the_nearest_slot() -> None:
    """A hint of 11:50 lands on the 12:00 slot, ignoring the due list."""
    with patch("diet_guard._claude_log.due_slots", return_value=(480,)) as due:
        assert resolve_slot(_request("normal", slot=710), NOON) == 720
    due.assert_not_called()


def test_log_estimate_writes_one_signed_claude_entry() -> None:
    """The entry carries the derived id, the estimate, the slot and the source."""
    with patch("diet_guard._claude_log.due_slots", return_value=(720,)):
        data = log_estimate("RID1", EST, _request(), NOON)
    assert data["entry_id"] == entry_id_for("RID1")
    assert (data["kcal"], data["slot_min"], data["desc"]) == (410.0, 720, "2 jajka")
    (entry,) = next(iter(load_log().values()))
    assert entry["source"] == "claude"
    assert entry_slot_minute(entry) == 720
    assert "components" not in entry


def test_components_are_carried_onto_the_entry() -> None:
    """A composite estimate keeps its per-item numbers on the entry."""
    part = {"name": "jajko", "grams": 60.0, "kcal": 90.0, "protein_g": 6.0}
    est = Estimate(
        "x", 60.0, 90.0, 6.0, 0.5, 7.0, ({**part, "carbs_g": 0.5, "fat_g": 7.0},)
    )
    log_estimate("RID2", est, _request("normal"), NOON)
    (entry,) = next(iter(load_log().values()))
    assert [c["name"] for c in entry["components"]] == ["jajko"]


def test_replay_returns_the_existing_entry_without_logging_again() -> None:
    """The same rid twice: one entry, the second call echoes the first."""
    first = log_estimate("RID3", EST, _request("normal"), NOON)
    second = log_estimate("RID3", EST, _request("normal"), NOON)
    assert second == first
    assert sum(len(day) for day in load_log().values()) == 1
    assert already_logged("RID3") == first
    assert already_logged("never") is None


def test_property_each_rid_yields_exactly_one_entry() -> None:
    """Any replay order of any rids: one entry per distinct rid, never more.

    The log persists across hypothesis examples (one test, one tmp dir), so
    the expectation accumulates the rids seen so far.
    """
    seen: set[str] = set()

    @settings(
        max_examples=40,
        deadline=None,
        suppress_health_check=[HealthCheck.function_scoped_fixture],
    )
    @given(rids=st.lists(st.sampled_from("ABCDEF"), min_size=1, max_size=12))
    def replay(rids: list[str]) -> None:
        for rid in rids:
            log_estimate(rid, EST, _request("normal"), NOON)
        seen.update(rids)
        ids = {str(e["id"]) for day in load_log().values() for e in day}
        assert ids == {entry_id_for(rid) for rid in seen}

    replay()
