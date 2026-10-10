"""The Python half of the cross-language meal-slot parity gate.

``app/test/models/meal_schedule_vectors_test.dart`` asserts the *same*
expectations against the *same* ``tests/fixtures/meal_schedule_vectors.json``.
Two independently written suites from the same prose is not a gate -- one
shared input with one shared expected result is: a device that derives a slot
its peer never offers has a checkpoint that can never be satisfied, i.e. a
permanent lock.  Regenerate with ``scripts/build_meal_schedule_fixture.py``.
"""

from __future__ import annotations

from datetime import UTC, datetime
import json
from pathlib import Path
from typing import Any

import pytest

from diet_guard._meal_schedule import (
    MealSchedule,
    schedule_from_wire,
    schedule_to_wire,
)
from diet_guard._slot_wire import entry_slot_minute, slot_fields
from diet_guard._slots import (
    current_slot,
    elapsed_slots,
    missing_slots,
    nearest_slot,
    satisfied_slots,
    slot_for_log,
    slot_label,
    within_enforcement_window,
)

FIXTURE = (
    Path(__file__).resolve().parents[2] / "tests/fixtures/meal_schedule_vectors.json"
)


@pytest.fixture(name="vectors", scope="module")
def _vectors() -> dict[str, Any]:
    """The shared fixture.  ``Any``: decoded JSON whose shape is the contract."""
    with FIXTURE.open(encoding="utf-8") as handle:
        data: dict[str, Any] = json.load(handle)
        return data


def _schedule(row: list[int]) -> MealSchedule:
    """Return the schedule a ``[first, last, count]`` fixture row encodes."""
    return MealSchedule(*row)


def _at(minute: int) -> datetime:
    """Return a fixed datetime at ``minute`` of day (the date is irrelevant)."""
    return datetime(2026, 1, 1, minute // 60, minute % 60, tzinfo=UTC)


def test_fixture_is_present() -> None:
    """A relocation fails here with a clear reason, not as a KeyError later."""
    assert FIXTURE.is_file(), f"shared parity fixture missing at {FIXTURE}"


def test_schedules(vectors: dict[str, Any]) -> None:
    """Normalisation, slots, cutoff and wire encoding, row by row."""
    assert vectors["schedules"]
    for row in vectors["schedules"]:
        schedule = _schedule(row["input"])
        normalized = schedule.normalized()
        assert [
            normalized.first_minute,
            normalized.last_minute,
            normalized.count,
        ] == row["normalized"], row["input"]
        assert list(schedule.slots()) == row["slots"], row["input"]
        assert schedule.enforcement_end_minute == row["enforcement_end_minute"]
        assert schedule_to_wire(schedule) == row["wire"], row["input"]
        assert schedule_from_wire(row["wire"]) == normalized, row["input"]


def test_time_edges(vectors: dict[str, Any]) -> None:
    """Every clock-reading function agrees at each minute edge."""
    assert vectors["time_edges"]
    for row in vectors["time_edges"]:
        schedule, now = _schedule(row["schedule"]), _at(row["minute"])
        where = (row["schedule"], row["minute"])
        assert within_enforcement_window(now, schedule) == row["within_window"], where
        assert list(elapsed_slots(now, schedule)) == row["elapsed"], where
        assert current_slot(now, schedule) == row["current_slot"], where
        assert slot_for_log(now, schedule) == row["slot_for_log"], where


def test_missing(vectors: dict[str, Any]) -> None:
    """Missing slots given a set of satisfied slot minutes."""
    for row in vectors["missing"]:
        schedule, now = _schedule(row["schedule"]), _at(row["minute"])
        actual = missing_slots(now, set(row["logged"]), schedule)
        assert list(actual) == row["missing"], row


def test_nearest(vectors: dict[str, Any]) -> None:
    """Nearest slot, including exact-halfway ties and out-of-day minutes."""
    for row in vectors["nearest"]:
        actual = nearest_slot(row["minute"], _schedule(row["schedule"]))
        assert actual == row["nearest"], row


def test_satisfied(vectors: dict[str, Any]) -> None:
    """Satisfied slots, many-to-one included."""
    for row in vectors["satisfied"]:
        actual = satisfied_slots(row["entry_minutes"], _schedule(row["schedule"]))
        assert sorted(actual) == row["satisfied"], row["name"]


def test_labels(vectors: dict[str, Any]) -> None:
    """``HH:MM`` labels, wrapped into the day."""
    for row in vectors["labels"]:
        assert slot_label(row["minute"]) == row["label"], row


def test_schedule_wire_decode(vectors: dict[str, Any]) -> None:
    """Malformed and legacy ``sched:`` values decode identically."""
    for row in vectors["schedule_wire_decode"]:
        triple = row["schedule"]
        expected = None if triple is None else _schedule(triple)
        assert schedule_from_wire(row["raw"]) == expected, row


def test_slot_fields(vectors: dict[str, Any]) -> None:
    """The entry writer's fields, or a refusal for a minute outside the day."""
    for row in vectors["slot_fields"]:
        if row.get("error"):
            with pytest.raises(ValueError, match="outside"):
                slot_fields(row["minute"])
        else:
            assert slot_fields(row["minute"]) == row["fields"], row


def test_entry_slot_minute(vectors: dict[str, Any]) -> None:
    """The entry reader: ``slot_min`` wins, legacy hours, bools rejected."""
    for row in vectors["entry_slot_minute"]:
        assert entry_slot_minute(row["entry"]) == row["minute"], row
