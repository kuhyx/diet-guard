"""Tests for _resolve.py — the manual/bank/staple/OFF resolution precedence.

Real food-bank and staple lookups are used (both isolated/offline); only the
Open Food Facts network layer is mocked, via the estimator it delegates to.
"""

from __future__ import annotations

from unittest.mock import patch

from python_pkg.diet_guard._estimator import Nutrition
from python_pkg.diet_guard._foodbank import remember_food
from python_pkg.diet_guard._resolve import (
    ManualMacros,
    lookup_candidates,
    resolve_nutrition,
    suggest_foods,
)

_OFF = Nutrition(260, 12, 30, 10, 100, "openfoodfacts: Big Mac")


class TestResolveManual:
    """A manual calorie value, scaled from its stated basis."""

    def test_per_grams_scaled_to_eaten(self) -> None:
        """200 kcal per 100 g eaten as 330 g logs 660 kcal."""
        result = resolve_nutrition(
            "pasta",
            grams=330,
            manual_macros=ManualMacros(kcal=200, per_grams=100),
        )
        assert result is not None
        assert result.kcal == 660.0

    def test_no_basis_keeps_value(self) -> None:
        """With neither grams nor per-grams, the manual value is taken as-is."""
        result = resolve_nutrition("shake", manual_macros=ManualMacros(kcal=180))
        assert result is not None
        assert result.kcal == 180.0

    def test_grams_only_is_the_basis(self) -> None:
        """With grams but no per-grams, grams is the reference (no double scale)."""
        result = resolve_nutrition(
            "soup",
            grams=250,
            manual_macros=ManualMacros(kcal=300),
        )
        assert result is not None
        assert result.kcal == 300.0


class TestResolveBankAndStaple:
    """Local sources, before any network call."""

    def test_banked_food_scaled(self) -> None:
        """A banked food is rescaled to the amount eaten."""
        remember_food("carbonara", Nutrition(700, 20, 80, 30, 350, "manual"))
        result = resolve_nutrition("carbonara", grams=700)
        assert result is not None
        assert result.kcal == 1400.0

    def test_banked_food_no_grams(self) -> None:
        """Without grams, the banked macros are returned unscaled."""
        remember_food("carbonara", Nutrition(700, 20, 80, 30, 350, "manual"))
        result = resolve_nutrition("carbonara")
        assert result is not None
        assert result.kcal == 700.0

    def test_staple_before_off(self) -> None:
        """A bare staple resolves locally (and never hits OFF)."""
        result = resolve_nutrition("apple", grams=200)
        assert result is not None
        assert "staple: apple" in result.source

    def test_staple_no_grams(self) -> None:
        """A staple with no grams returns its per-100 g basis."""
        result = resolve_nutrition("egg")
        assert result is not None
        assert result.grams == 100.0

    def test_off_fallback(self) -> None:
        """An unknown, non-staple food falls through to Open Food Facts."""
        with patch(
            "python_pkg.diet_guard._resolve.estimate_off",
            return_value=_OFF,
        ):
            result = resolve_nutrition("exotic dish")
        assert result is not None
        assert "openfoodfacts" in result.source


class TestLookupCandidates:
    """Reviewable candidates for the blank-calorie gate path."""

    def test_banked_candidate(self) -> None:
        """A banked food yields a single scaled candidate under its name."""
        remember_food("oats", Nutrition(380, 13, 67, 7, 100, "manual"))
        candidates = lookup_candidates("oats", grams=200)
        assert candidates[0][0] == "oats"
        assert candidates[0][1].kcal == 760.0

    def test_banked_candidate_no_grams(self) -> None:
        """Without grams the banked candidate is unscaled."""
        remember_food("oats", Nutrition(380, 13, 67, 7, 100, "manual"))
        assert lookup_candidates("oats")[0][1].kcal == 380.0

    def test_staple_candidate(self) -> None:
        """A staple yields a candidate labelled by its source."""
        candidates = lookup_candidates("banana", grams=100)
        assert "staple: banana" in candidates[0][0]

    def test_staple_candidate_no_grams(self) -> None:
        """A staple candidate with no grams stays at its 100 g basis."""
        assert lookup_candidates("banana")[0][1].grams == 100.0

    def test_off_candidates(self) -> None:
        """An unknown food returns the OFF alternatives, labelled by source."""
        with patch(
            "python_pkg.diet_guard._resolve.off_candidates",
            return_value=[_OFF],
        ):
            candidates = lookup_candidates("exotic dish")
        assert candidates[0][0] == _OFF.source


class TestSuggestFoods:
    """Merged bank + staple autocomplete."""

    def test_bank_ranked_first(self) -> None:
        """A banked food appears ahead of staples for the same query."""
        remember_food("apple pie", Nutrition(300, 3, 50, 12, 120, "manual"))
        names = [name for name, _ in suggest_foods("apple")]
        assert names[0] == "apple pie"
        assert "apple" in names

    def test_staple_not_duplicated(self) -> None:
        """A staple already banked under the same name is not duplicated."""
        remember_food("apple", Nutrition(95, 0, 25, 0, 182, "manual"))
        names = [name for name, _ in suggest_foods("apple")]
        assert names.count("apple") == 1
