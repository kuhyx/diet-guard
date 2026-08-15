"""Tests for _foodbank.py — the local corpus of previously logged foods.

The food-bank file is redirected into ``tmp_path`` by the autouse conftest
fixture, so every read/write here is isolated from real user data.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

from diet_guard import _foodbank, _foodbank_rebuild
from diet_guard._estimator import Nutrition
from diet_guard._foodbank import remember_food
from diet_guard._foodbank_search import lookup_food

_NUT = Nutrition(
    kcal=250,
    protein_g=12,
    carbs_g=30,
    fat_g=10,
    grams=200,
    source="manual",
)


class TestRebuildFoodBank:
    """Replaying a full log into a fresh bank, mirroring the Dart port."""

    def test_rebuilds_a_simple_food_entry(self) -> None:
        log = {
            "2026-06-22": [
                {
                    "id": "a",
                    "time": "2026-06-22T08:00:00+02:00",
                    "desc": "toast",
                    "kcal": 150.0,
                    "protein_g": 5.0,
                    "carbs_g": 20.0,
                    "fat_g": 3.0,
                    "grams": 50.0,
                    "source": "manual",
                },
            ],
        }
        bank = _foodbank_rebuild.rebuild_food_bank(log)
        assert lookup_food("toast") is not None
        assert bank["toast"]["count"] == 1

    def test_skips_tombstoned_entries(self) -> None:
        log = {
            "2026-06-22": [
                {
                    "id": "a",
                    "time": "2026-06-22T08:00:00+02:00",
                    "desc": "toast",
                    "kcal": 150.0,
                    "protein_g": 5.0,
                    "carbs_g": 20.0,
                    "fat_g": 3.0,
                    "grams": 50.0,
                    "source": "manual",
                    "deleted": True,
                },
            ],
        }
        bank = _foodbank_rebuild.rebuild_food_bank(log)
        assert bank == {}

    def test_banks_each_component_and_the_composite(self) -> None:
        log = {
            "2026-06-22": [
                {
                    "id": "a",
                    "time": "2026-06-22T20:00:00+02:00",
                    "desc": "dinner",
                    "kcal": 465.0,
                    "protein_g": 37.0,
                    "carbs_g": 66.0,
                    "fat_g": 5.5,
                    "grams": 300.0,
                    "source": "meal",
                    "components": [
                        {
                            "name": "rice",
                            "kcal": 300.0,
                            "protein_g": 6.0,
                            "carbs_g": 66.0,
                            "fat_g": 1.5,
                            "grams": 150.0,
                        },
                        {
                            "name": "chicken",
                            "kcal": 165.0,
                            "protein_g": 31.0,
                            "carbs_g": 0.0,
                            "fat_g": 4.0,
                            "grams": 150.0,
                        },
                    ],
                },
            ],
        }
        _foodbank_rebuild.rebuild_food_bank(log)
        assert lookup_food("rice") is not None
        assert lookup_food("chicken") is not None
        composite = lookup_food("dinner")
        assert composite is not None
        assert composite.kcal == 465.0

    def test_replays_in_time_then_id_order_so_count_and_latest_macros_agree(
        self,
    ) -> None:
        log = {
            "2026-06-22": [
                {
                    "id": "b",
                    "time": "2026-06-22T12:00:00+02:00",
                    "desc": "toast",
                    "kcal": 999.0,
                    "protein_g": 0.0,
                    "carbs_g": 0.0,
                    "fat_g": 0.0,
                    "grams": 0.0,
                    "source": "manual",
                },
                {
                    "id": "a",
                    "time": "2026-06-22T08:00:00+02:00",
                    "desc": "toast",
                    "kcal": 150.0,
                    "protein_g": 5.0,
                    "carbs_g": 20.0,
                    "fat_g": 3.0,
                    "grams": 50.0,
                    "source": "manual",
                },
            ],
        }
        bank = _foodbank_rebuild.rebuild_food_bank(log)
        # Replayed oldest-first (08:00 then 12:00) regardless of list order,
        # so the 12:00 entry's macros are the ones that survive.
        assert bank["toast"]["kcal"] == 999.0
        assert bank["toast"]["count"] == 2

    def test_persists_to_disk(self) -> None:
        log = {
            "2026-06-22": [
                {
                    "id": "a",
                    "time": "2026-06-22T08:00:00+02:00",
                    "desc": "toast",
                    "kcal": 150.0,
                    "protein_g": 5.0,
                    "carbs_g": 20.0,
                    "fat_g": 3.0,
                    "grams": 50.0,
                    "source": "manual",
                },
            ],
        }
        _foodbank_rebuild.rebuild_food_bank(log)
        # A fresh read (not the in-memory return value) must also see it.
        assert lookup_food("toast") is not None

    def test_ignores_a_non_dict_component(self) -> None:
        log = {
            "2026-06-22": [
                {
                    "id": "a",
                    "time": "2026-06-22T08:00:00+02:00",
                    "desc": "dinner",
                    "kcal": 100.0,
                    "protein_g": 1.0,
                    "carbs_g": 1.0,
                    "fat_g": 1.0,
                    "grams": 100.0,
                    "source": "meal",
                    "components": ["not-a-dict"],
                },
            ],
        }
        _foodbank_rebuild.rebuild_food_bank(log)
        assert lookup_food("dinner") is not None


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
