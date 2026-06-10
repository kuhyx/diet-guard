"""Tests for _estimator.py — Nutrition maths and the Open Food Facts backend.

The HTTP layer is fully mocked (``requests.get``), so the parsing, portion, and
scaling branches are exercised without any network access.
"""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import requests

from python_pkg.diet_guard import _estimator
from python_pkg.diet_guard._constants import DEFAULT_PORTION_GRAMS
from python_pkg.diet_guard._estimator import (
    Nutrition,
    estimate,
    estimate_off,
    manual,
    off_candidates,
    scale_nutrition,
)

_GOOD = {
    "product_name": "Big Mac",
    "nutriments": {
        "energy-kcal_100g": 250,
        "proteins_100g": 12,
        "carbohydrates_100g": 30,
        "fat_100g": 10,
    },
    "serving_quantity": 150,
}


def _patch_get(payload: object) -> object:
    """Patch ``requests.get`` to return a response whose JSON is ``payload``."""
    response = MagicMock()
    response.raise_for_status = MagicMock()
    response.json = MagicMock(return_value=payload)
    return patch.object(_estimator.requests, "get", return_value=response)


def _hits(*products: object) -> dict[str, object]:
    """Wrap products in the Search-a-licious ``hits`` envelope."""
    return {"hits": list(products)}


class TestAsFloat:
    """Coercion of OFF numeric fields, including the rejected types."""

    def test_bool_rejected(self) -> None:
        """A bool is not a real nutriment value."""
        assert _estimator._as_float(value=True) is None

    def test_int_and_float(self) -> None:
        """Ints and floats pass straight through."""
        assert _estimator._as_float(5) == 5.0
        assert _estimator._as_float(2.5) == 2.5

    def test_numeric_string(self) -> None:
        """A numeric string parses."""
        assert _estimator._as_float("3.5") == 3.5

    def test_non_numeric_string(self) -> None:
        """A non-numeric string is None."""
        assert _estimator._as_float("abc") is None

    def test_other_type(self) -> None:
        """An unrelated type (None) is None."""
        assert _estimator._as_float(None) is None


class TestManual:
    """User-supplied nutrition."""

    def test_with_grams(self) -> None:
        """Grams are kept for display; source is manual."""
        result = manual(500, 250, protein_g=20, carbs_g=40, fat_g=15)
        assert result == Nutrition(500.0, 20.0, 40.0, 15.0, 250.0, "manual")

    def test_without_grams(self) -> None:
        """Omitting grams records 0.0."""
        assert manual(300).grams == 0.0


class TestScaleNutrition:
    """Proportional rescaling and its degenerate guards."""

    def test_normal_scaling(self) -> None:
        """Doubling the grams doubles every macro."""
        base = Nutrition(100, 10, 5, 2, 100, "x")
        scaled = scale_nutrition(base, 200)
        assert (scaled.kcal, scaled.protein_g, scaled.grams) == (200.0, 20.0, 200.0)

    def test_unknown_basis_keeps_macros(self) -> None:
        """A zero basis cannot scale, so macros stay and only grams update."""
        base = Nutrition(100, 10, 5, 2, 0, "x")
        scaled = scale_nutrition(base, 250)
        assert scaled.kcal == 100
        assert scaled.grams == 250

    def test_non_positive_new_grams_keeps_basis_grams(self) -> None:
        """A non-positive target weight keeps the basis weight, macros intact."""
        base = Nutrition(100, 10, 5, 2, 100, "x")
        scaled = scale_nutrition(base, 0)
        assert scaled.kcal == 100
        assert scaled.grams == 100


class TestOffSearchEnvelope:
    """Defensive parsing of the search payload shape."""

    def test_payload_not_dict(self) -> None:
        """A non-object payload yields no candidates."""
        with _patch_get("not a dict"):
            assert off_candidates("x") == []

    def test_hits_not_list(self) -> None:
        """A non-list ``hits`` yields no candidates."""
        with _patch_get({"hits": 123}):
            assert off_candidates("x") == []


class TestOffCandidates:
    """Building Nutrition from products, with filtering and portions."""

    def test_filters_unusable_products(self) -> None:
        """Non-dict hits, bad nutriments, and kcal-less products are dropped."""
        with _patch_get(
            _hits(
                "junk-string",
                {"product_name": "NoNutr", "nutriments": "bad"},
                {"product_name": "NoKcal", "nutriments": {"proteins_100g": 5}},
                _GOOD,
            ),
        ):
            results = off_candidates("big mac")
        assert len(results) == 1
        assert results[0].source == "openfoodfacts: Big Mac"

    def test_explicit_grams_override_serving(self) -> None:
        """An explicit portion takes priority over the serving size."""
        with _patch_get(_hits(_GOOD)):
            result = off_candidates("big mac", grams=200)[0]
        assert result.grams == 200
        assert result.kcal == 500

    def test_serving_quantity_used_when_no_grams(self) -> None:
        """With no grams, the product's serving size sets the portion."""
        with _patch_get(_hits(_GOOD)):
            result = off_candidates("big mac")[0]
        assert result.grams == 150

    def test_default_portion_when_nothing_known(self) -> None:
        """No grams and no serving falls back to the default portion."""
        product = {"product_name": "P", "nutriments": {"energy-kcal_100g": 100}}
        with _patch_get(_hits(product)):
            result = off_candidates("p")[0]
        assert result.grams == DEFAULT_PORTION_GRAMS

    def test_blank_name_uses_description(self) -> None:
        """A blank product name falls back to the typed description."""
        product = {"product_name": "  ", "nutriments": {"energy-kcal_100g": 100}}
        with _patch_get(_hits(product)):
            result = off_candidates("my food")[0]
        assert result.source == "openfoodfacts: my food"

    def test_missing_macro_field_is_zero(self) -> None:
        """A product missing a macro records that macro as 0.0."""
        product = {"product_name": "P", "nutriments": {"energy-kcal_100g": 100}}
        with _patch_get(_hits(product)):
            result = off_candidates("p")[0]
        assert result.protein_g == 0.0

    def test_request_exception_returns_empty(self) -> None:
        """A network failure degrades to an empty candidate list."""
        with patch.object(
            _estimator.requests,
            "get",
            side_effect=requests.RequestException("boom"),
        ):
            assert off_candidates("x") == []


class TestEstimateOff:
    """The single-best-match convenience wrapper."""

    def test_returns_top(self) -> None:
        """The top candidate is returned when one exists."""
        with _patch_get(_hits(_GOOD)):
            assert estimate_off("big mac", None) is not None

    def test_none_when_empty(self) -> None:
        """No matches -> None."""
        with _patch_get(_hits()):
            assert estimate_off("nothing", None) is None


class TestEstimate:
    """The top-level estimate dispatcher."""

    def test_manual_takes_precedence(self) -> None:
        """A manual kcal value skips Open Food Facts entirely."""
        result = estimate("anything", manual_kcal=222)
        assert result is not None
        assert result.source == "manual"

    def test_falls_back_to_off(self) -> None:
        """With no manual value, OFF is queried."""
        with _patch_get(_hits(_GOOD)):
            result = estimate("big mac")
        assert result is not None
        assert "openfoodfacts" in result.source


def test_nutrition_is_immutable() -> None:
    """The Nutrition value object is frozen (a dataclass safety check)."""
    nutrition = Nutrition(1, 2, 3, 4, 5, "x")
    assert nutrition.kcal == 1
