"""Tests for _foodbank.py — the local corpus of previously logged foods.

The food-bank file is redirected into ``tmp_path`` by the autouse conftest
fixture, so every read/write here is isolated from real user data.
"""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

from python_pkg.diet_guard import _foodbank
from python_pkg.diet_guard._estimator import Nutrition
from python_pkg.diet_guard._foodbank import (
    lookup_food,
    remember_food,
    remember_meal,
    search_foods,
)
from python_pkg.diet_guard._meal import MealItem

_NUT = Nutrition(
    kcal=250,
    protein_g=12,
    carbs_g=30,
    fat_g=10,
    grams=200,
    source="manual",
)


def _write_raw(bank: object) -> None:
    """Write an arbitrary object as the bank file (for defensive-read tests)."""
    _foodbank.FOOD_BANK_FILE.write_text(json.dumps(bank), encoding="utf-8")


class TestAsFloat:
    """Field coercion with the bool rejection."""

    def test_bool_is_zero(self) -> None:
        """A bool is not a real count/macro."""
        assert _foodbank._as_float(value=True) == 0.0

    def test_number_passes(self) -> None:
        """Ints and floats pass through."""
        assert _foodbank._as_float(7) == 7.0

    def test_other_is_zero(self) -> None:
        """A non-numeric value defaults to 0.0."""
        assert _foodbank._as_float("x") == 0.0


class TestRememberAndLookup:
    """Round-tripping foods through the bank."""

    def test_blank_description_ignored(self) -> None:
        """A blank name is not stored."""
        remember_food("   ", _NUT)
        assert lookup_food("   ") is None

    def test_roundtrip_case_insensitive(self) -> None:
        """A remembered food is found regardless of case."""
        remember_food("Big Mac", _NUT)
        found = lookup_food("big mac")
        assert found is not None
        assert found.kcal == 250
        assert found.source == "food bank"

    def test_lookup_miss(self) -> None:
        """An unknown food looks up to None."""
        assert lookup_food("nope") is None

    def test_recording_twice_bumps_count(self) -> None:
        """Re-logging a food increments its use count (raises its ranking)."""
        remember_food("oats", _NUT)
        remember_food("oats", _NUT)
        bank = json.loads(_foodbank.FOOD_BANK_FILE.read_text(encoding="utf-8"))
        assert bank["oats"]["count"] == 2


class TestReadDefensive:
    """The bank read tolerates a missing or corrupt file."""

    def test_missing_file(self) -> None:
        """No file yet -> empty results."""
        assert search_foods("anything") == []

    def test_corrupt_json(self) -> None:
        """Unparsable content -> empty bank."""
        _foodbank.FOOD_BANK_FILE.write_text("not json", encoding="utf-8")
        assert search_foods("x") == []

    def test_top_level_not_dict(self) -> None:
        """A non-object top level -> empty bank."""
        _write_raw([1, 2, 3])
        assert search_foods("x") == []

    def test_non_dict_records_filtered(self) -> None:
        """Records that are not objects are dropped on read."""
        _write_raw({"good": {"desc": "good", "kcal": 5, "count": 1}, "bad": 123})
        names = [name for name, _ in search_foods("")]
        assert names == ["good"]


class TestSearch:
    """Ranked autocomplete search."""

    def test_empty_query_ranks_by_count(self) -> None:
        """An empty query returns all foods, most-logged first."""
        remember_food("rare", _NUT)
        remember_food("common", _NUT)
        remember_food("common", _NUT)
        names = [name for name, _ in search_foods("")]
        assert names[0] == "common"

    def test_substring_match(self) -> None:
        """A substring of a stored name matches it."""
        remember_food("chicken breast", _NUT)
        names = [name for name, _ in search_foods("breast")]
        assert "chicken breast" in names

    def test_typo_within_threshold(self) -> None:
        """A close typo still matches via the fuzzy scorer."""
        remember_food("chicken", _NUT)
        names = [name for name, _ in search_foods("chiken")]
        assert "chicken" in names

    def test_below_threshold_filtered(self) -> None:
        """A wildly different query returns nothing."""
        remember_food("chicken", _NUT)
        assert search_foods("xylophone") == []

    def test_display_name_falls_back_to_key(self) -> None:
        """A record with no usable desc displays under its key."""
        _write_raw({"applekey": {"kcal": 50, "count": 1}})
        names = [name for name, _ in search_foods("")]
        assert names == ["applekey"]


class TestRememberMeal:
    """Banking a composite meal and its components."""

    def test_banks_each_item_and_the_composite(self) -> None:
        """Every component and the summed meal land in the bank."""
        items = [
            MealItem("salad", Nutrition(80, 2, 8, 5, 120, "manual")),
            MealItem("chicken", Nutrition(330, 62, 0, 7, 200, "manual")),
        ]
        total = remember_meal("dinner", items)
        assert total.kcal == 410
        assert lookup_food("salad") is not None
        assert lookup_food("chicken") is not None
        dinner = lookup_food("dinner")
        assert dinner is not None
        assert dinner.kcal == 410

    def test_composite_records_components(self) -> None:
        """The meal entry carries its component names for later use."""
        item = MealItem("rice", Nutrition(260, 5, 56, 1, 180, "manual"))
        remember_meal("bowl", [item])
        bank = json.loads(_foodbank.FOOD_BANK_FILE.read_text(encoding="utf-8"))
        assert bank["bowl"]["components"] == ["rice"]

    def test_blank_name_banks_items_only(self) -> None:
        """A blank meal name still banks items but stores no empty composite."""
        item = MealItem("toast", Nutrition(120, 4, 20, 2, 40, "manual"))
        remember_meal("   ", [item])
        assert lookup_food("toast") is not None
        bank = json.loads(_foodbank.FOOD_BANK_FILE.read_text(encoding="utf-8"))
        assert list(bank) == ["toast"]


class TestCorruptQuarantine:
    """A corrupt bank is moved aside, not re-warned about or overwritten."""

    def test_corrupt_file_is_moved_aside(self) -> None:
        """Reading a corrupt bank quarantines it and returns empty."""
        _foodbank.FOOD_BANK_FILE.write_text("{ broken", encoding="utf-8")
        assert _foodbank._read_bank() == {}
        assert not _foodbank.FOOD_BANK_FILE.exists()
        backups = list(
            _foodbank.FOOD_BANK_FILE.parent.glob("food_bank.json.corrupt-*"),
        )
        assert len(backups) == 1
        assert backups[0].read_text(encoding="utf-8") == "{ broken"

    def test_subsequent_reads_silent_and_empty(self) -> None:
        """After quarantine the next reads find no file (no warning flood)."""
        _foodbank.FOOD_BANK_FILE.write_text("nope", encoding="utf-8")
        assert _foodbank._read_bank() == {}
        assert _foodbank._read_bank() == {}
        assert _foodbank._read_bank() == {}

    def test_corrupt_then_remember_starts_fresh(self) -> None:
        """A new entry after corruption writes a fresh bank, losing nothing."""
        _foodbank.FOOD_BANK_FILE.write_text("{ broken", encoding="utf-8")
        remember_food("eggs", _NUT)
        assert lookup_food("eggs") is not None
        assert list(_foodbank.FOOD_BANK_FILE.parent.glob("food_bank.json.corrupt-*"))

    def test_rename_failure_is_handled(self) -> None:
        """If the corrupt file cannot be moved, the read still returns empty."""
        _foodbank.FOOD_BANK_FILE.write_text("{ broken", encoding="utf-8")
        with patch.object(Path, "rename", side_effect=OSError("locked")):
            assert _foodbank._read_bank() == {}
