"""Tests for _foodbank.py — the local corpus of previously logged foods.

The food-bank file is redirected into ``tmp_path`` by the autouse conftest
fixture, so every read/write here is isolated from real user data.
"""

from __future__ import annotations

import json

from diet_guard import _foodbank
from diet_guard._estimator import Nutrition
from diet_guard._foodbank import remember_food
from diet_guard._foodbank_search import lookup_food, search_foods

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
