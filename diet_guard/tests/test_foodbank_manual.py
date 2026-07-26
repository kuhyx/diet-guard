"""Tests for _foodbank_manual.py — the hand-curated, synced bank entries.

The manual-bank file is redirected into ``tmp_path`` by the autouse conftest
fixture, so every read/write here is isolated from real user data.
"""

from __future__ import annotations

import json

from diet_guard import _foodbank, _foodbank_manual
from diet_guard._estimator import Nutrition
from diet_guard._foodbank import lookup_food, remember_food, search_foods
from diet_guard._foodbank_manual import (
    add_manual_entry,
    read_manual_bank,
    record_edit_time,
    write_manual_bank,
)

_SKYR = {
    "desc": "Skyr",
    "kcal": 120.0,
    "protein_g": 20.0,
    "carbs_g": 5.0,
    "fat_g": 0.5,
    "grams": 150.0,
    "count": 0,
}


class TestFileIO:
    """Reading and writing the curated bank."""

    def test_absent_file_reads_as_empty(self) -> None:
        assert read_manual_bank() == {}

    def test_write_then_read_round_trips(self) -> None:
        write_manual_bank({"skyr": dict(_SKYR)})
        assert read_manual_bank()["skyr"]["kcal"] == 120.0

    def test_unreadable_file_reads_as_empty(self) -> None:
        _foodbank_manual.MANUAL_BANK_FILE.parent.mkdir(parents=True, exist_ok=True)
        _foodbank_manual.MANUAL_BANK_FILE.write_text("not json{{{")
        assert read_manual_bank() == {}

    def test_non_object_file_reads_as_empty(self) -> None:
        _foodbank_manual.MANUAL_BANK_FILE.parent.mkdir(parents=True, exist_ok=True)
        _foodbank_manual.MANUAL_BANK_FILE.write_text("[1, 2, 3]")
        assert read_manual_bank() == {}

    def test_non_dict_records_are_dropped(self) -> None:
        _foodbank_manual.MANUAL_BANK_FILE.parent.mkdir(parents=True, exist_ok=True)
        _foodbank_manual.MANUAL_BANK_FILE.write_text(
            json.dumps({"skyr": _SKYR, "junk": "not a record"}),
        )
        assert set(read_manual_bank()) == {"skyr"}


class TestEditTime:
    """The edit stamp the sync merge orders by."""

    def test_missing_stamp_reads_as_the_epoch(self) -> None:
        assert record_edit_time({}).startswith("1970-01-01")

    def test_non_string_stamp_reads_as_the_epoch(self) -> None:
        assert record_edit_time({"t": 12345}).startswith("1970-01-01")

    def test_add_stamps_the_edit(self) -> None:
        add_manual_entry("Skyr", dict(_SKYR))
        assert not record_edit_time(read_manual_bank()["skyr"]).startswith("1970")


class TestAddManualEntry:
    """Adding curated foods."""

    def test_keys_on_the_normalized_name(self) -> None:
        add_manual_entry("  SkYr  ", dict(_SKYR))
        assert set(read_manual_bank()) == {"skyr"}

    def test_repeated_add_replaces_rather_than_duplicating(self) -> None:
        add_manual_entry("Skyr", dict(_SKYR))
        add_manual_entry("Skyr", {**_SKYR, "kcal": 130.0})
        bank = read_manual_bank()
        assert len(bank) == 1
        assert bank["skyr"]["kcal"] == 130.0


class TestVisibleToTheBank:
    """Curated entries must be usable exactly like logged ones.

    This is the whole point of syncing them: a food added by hand on the
    phone has to resolve in the PC gate's autocomplete without ever having
    been eaten.
    """

    def test_lookup_finds_a_curated_food(self) -> None:
        add_manual_entry("Skyr", dict(_SKYR))
        found = lookup_food("skyr")
        assert found is not None
        assert found.kcal == 120.0

    def test_search_finds_a_curated_food(self) -> None:
        add_manual_entry("Skyr", dict(_SKYR))
        assert [name for name, _ in search_foods("sky")] == ["Skyr"]

    def test_empty_query_lists_curated_foods_too(self) -> None:
        add_manual_entry("Skyr", dict(_SKYR))
        assert [name for name, _ in search_foods("")] == ["Skyr"]

    def test_a_logged_food_wins_a_name_collision(self) -> None:
        """A logged record carries a real count and the macros actually eaten."""
        add_manual_entry("Skyr", {**_SKYR, "kcal": 120.0})
        remember_food("Skyr", Nutrition(999, 1, 1, 1, 100, "manual"))
        found = lookup_food("Skyr")
        assert found is not None
        assert found.kcal == 999

    def test_a_curated_food_survives_a_bank_rebuild(self) -> None:
        """The derived bank is rewritten on every log write; curated entries
        live in their own file precisely so that cannot wipe them."""
        add_manual_entry("Skyr", dict(_SKYR))
        _foodbank.rebuild_food_bank({})
        assert lookup_food("Skyr") is not None
