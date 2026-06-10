"""Tests for _portions.py — built-in staple weights and macros.

Covers the fuzzy staple match, the empty-input guard, and the per-100 g
Nutrition / suggestion builders.
"""

from __future__ import annotations

from python_pkg.diet_guard._portions import (
    estimate_unit_grams,
    staple_nutrition,
    suggest_staples,
)


class TestEstimateUnitGrams:
    """One piece's typical weight."""

    def test_known_staple(self) -> None:
        """A known staple returns its curated unit weight."""
        assert estimate_unit_grams("apple") == 182.0

    def test_fuzzy_plural(self) -> None:
        """A close variant (plural) still matches the staple."""
        assert estimate_unit_grams("apples") == 182.0

    def test_unknown_returns_none(self) -> None:
        """An unrecognised food has no known unit weight."""
        assert estimate_unit_grams("quinoa risotto") is None

    def test_empty_returns_none(self) -> None:
        """A blank description short-circuits to None."""
        assert estimate_unit_grams("   ") is None


class TestStapleNutrition:
    """Per-100 g Nutrition for a staple."""

    def test_known_staple_per_100g(self) -> None:
        """An egg resolves to its per-100 g macros at a 100 g basis."""
        nutrition = staple_nutrition("egg")
        assert nutrition is not None
        assert nutrition.grams == 100.0
        assert nutrition.source == "staple: egg"

    def test_unknown_returns_none(self) -> None:
        """A non-staple resolves to None."""
        assert staple_nutrition("beef wellington") is None


class TestSuggestStaples:
    """Live autocomplete over the staple table."""

    def test_match(self) -> None:
        """A matching query surfaces the staple by name."""
        names = [name for name, _ in suggest_staples("banana")]
        assert "banana" in names

    def test_empty_query(self) -> None:
        """A blank query suggests nothing."""
        assert suggest_staples("") == []

    def test_no_match(self) -> None:
        """A query matching no staple returns an empty list."""
        assert suggest_staples("xyzzy") == []
