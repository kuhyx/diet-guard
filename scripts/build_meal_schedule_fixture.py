#!/usr/bin/env python3
"""Regenerate the shared cross-language meal-schedule parity fixture.

The fixture (``tests/fixtures/meal_schedule_vectors.json``) is read by *both*
``diet_guard/tests/test_meal_schedule_vectors.py`` and
``app/test/models/meal_schedule_vectors_test.dart``: one shared input, one
shared expected result, so the PC and the phone derive the same slot minutes,
attribute a meal to the same slot and read the same wire fields.  A slot one
device offers while the other does not is a checkpoint that can never be
satisfied -- a permanent lock.  The inputs live in
``scripts/meal_schedule_cases.py``.

``expected`` values come from the Python implementation, the reference the Dart
port must reproduce -- so regenerating blesses whatever Python does now. Only
run it after an intended change, and re-read the diff before committing.

Run it from the repo root with the repo on the path, so ``diet_guard``
resolves to *this* tree rather than wherever the editable install
points:

    PYTHONPATH="$PWD" python3 scripts/build_meal_schedule_fixture.py
"""

from __future__ import annotations

from datetime import UTC, datetime
from itertools import pairwise
import json
from pathlib import Path

import meal_schedule_cases as cases

from diet_guard._meal_schedule import (
    MINUTES_PER_DAY,
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
    Path(__file__).resolve().parent.parent / "tests/fixtures/meal_schedule_vectors.json"
)


def _triple(schedule: MealSchedule | None) -> list[int] | None:
    """Return a schedule as the ``[first, last, count]`` row it is stored as."""
    if schedule is None:
        return None
    return [schedule.first_minute, schedule.last_minute, schedule.count]


def _at(minute: int) -> datetime:
    """Return a fixed datetime at ``minute`` of day (the date is irrelevant)."""
    return datetime(2026, 1, 1, minute // 60, minute % 60, tzinfo=UTC)


def _schedule_row(triple: cases.Triple) -> dict[str, object]:
    """Return one schedule's normalised form, slots, cutoff and wire encoding."""
    schedule = MealSchedule(*triple)
    return {
        "input": list(triple),
        "normalized": _triple(schedule.normalized()),
        "slots": list(schedule.slots()),
        "enforcement_end_minute": schedule.enforcement_end_minute,
        "wire": schedule_to_wire(schedule),
    }


def _edge_minutes(schedule: MealSchedule) -> list[int]:
    """Return every minute around a slot or the cutoff, plus the day's ends."""
    around = [schedule.enforcement_end_minute, *schedule.slots()]
    minutes = {0, 1439} | {m + d for m in around for d in (-1, 0, 1)}
    return sorted(m for m in minutes if 0 <= m < MINUTES_PER_DAY)


def _edge_row(triple: cases.Triple, minute: int) -> dict[str, object]:
    """Return what every clock-reading function says at ``minute``."""
    schedule, now = MealSchedule(*triple), _at(minute)
    return {
        "schedule": list(triple),
        "minute": minute,
        "within_window": within_enforcement_window(now, schedule),
        "elapsed": list(elapsed_slots(now, schedule)),
        "current_slot": current_slot(now, schedule),
        "slot_for_log": slot_for_log(now, schedule),
    }


def _nearest_minutes(schedule: MealSchedule) -> list[int]:
    """Return each slot, each midpoint +/- 1, and out-of-day minutes."""
    slots = schedule.slots()
    mids = [(a + b) // 2 for a, b in pairwise(slots)]
    minutes = {-60, 0, 1439, 1800, *slots}
    minutes |= {m + d for m in mids for d in (-1, 0, 1)}
    return sorted(minutes)


def _slot_field_row(minute: int) -> dict[str, object]:
    """Return ``slot_fields(minute)``, or an error marker when it raises."""
    try:
        return {"minute": minute, "fields": slot_fields(minute)}
    except ValueError:
        return {"minute": minute, "error": True}


def _missing_row(triple: cases.Triple, minute: int, logged: list[int]) -> object:
    """Return the unsatisfied elapsed slots at ``minute`` given ``logged``."""
    missing = missing_slots(_at(minute), set(logged), MealSchedule(*triple))
    return {
        "schedule": list(triple),
        "minute": minute,
        "logged": logged,
        "missing": list(missing),
    }


def _satisfied_row(name: str, triple: cases.Triple, minutes: list[int]) -> object:
    """Return the slots ``minutes`` satisfy under ``triple``, sorted."""
    satisfied = satisfied_slots(minutes, MealSchedule(*triple))
    return {
        "name": name,
        "schedule": list(triple),
        "entry_minutes": minutes,
        "satisfied": sorted(satisfied),
    }


def build() -> dict[str, object]:
    """Return the whole fixture: every input with its expected result."""
    edge = [(t, MealSchedule(*t)) for t in cases.EDGE_SCHEDULES]
    return {
        "_comment": (
            "Shared parity fixture for meal-slot minutes. Read by BOTH "
            "diet_guard/tests/test_meal_schedule_vectors.py and "
            "app/test/models/meal_schedule_vectors_test.dart. Regenerate with "
            "scripts/build_meal_schedule_fixture.py."
        ),
        "schedules": [_schedule_row(t) for t in cases.SCHEDULES],
        "time_edges": [_edge_row(t, m) for t, s in edge for m in _edge_minutes(s)],
        "missing": [_missing_row(*case) for case in cases.MISSING],
        "nearest": [
            {"schedule": list(t), "minute": m, "nearest": nearest_slot(m, s)}
            for t, s in edge
            for m in _nearest_minutes(s)
        ],
        "satisfied": [_satisfied_row(*case) for case in cases.SATISFIED],
        "labels": [{"minute": m, "label": slot_label(m)} for m in cases.LABELS],
        "schedule_wire_decode": [
            {"raw": raw, "schedule": _triple(schedule_from_wire(raw))}
            for raw in cases.WIRE_DECODE
        ],
        "slot_fields": [_slot_field_row(m) for m in cases.SLOT_FIELD_MINUTES],
        "entry_slot_minute": [
            {"entry": entry, "minute": entry_slot_minute(entry)}
            for entry in cases.ENTRIES
        ],
    }


def main() -> None:
    """Write the fixture to disk.

    Deliberately silent: ``T201`` bans ``print`` here, and the script's output
    is the file itself -- ``git diff`` is how you check what changed.
    """
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    with FIXTURE.open("w", encoding="utf-8") as handle:
        json.dump(build(), handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    main()
