"""Calorie/macro estimation backends for diet_guard.

The default backend queries the public Open Food Facts (OFF) database over
HTTP -- no API key required.  It is strongest for branded/packaged foods
(fast food included, which is the binge target) and weaker for generic
home-cooked descriptions; in the latter case the caller should fall back to a
manual ``--kcal`` value.

The backend is intentionally small and pluggable: replace :func:`estimate`
with a local-LLM (ollama) or remote-LLM implementation later without touching
the log/state or CLI layers.
"""

from __future__ import annotations

from importlib import import_module
import logging
import sys
from typing import TYPE_CHECKING

from diet_guard._constants import (
    DEFAULT_PORTION_GRAMS,
    OFF_PAGE_SIZE,
    OFF_SEARCH_URL,
    OFF_TIMEOUT_SECONDS,
    OFF_USER_AGENT,
)
from diet_guard._estimator import Nutrition, _as_float, manual

if TYPE_CHECKING:
    from types import ModuleType

_logger = logging.getLogger(__name__)


# ``requests`` costs ~70ms to import and this module is reachable from every
# CLI subcommand via ``_resolve`` -> ``_cli_log``, so importing it eagerly
# taxed ``gate --check`` -- which never looks a food up. Only the Open Food
# Facts calls below need it, and those are network calls already.
#
# A module-level ``__getattr__`` (PEP 562) rather than function-local imports
# so ``patch("diet_guard._estimator_off.requests")`` still resolves: the patch
# sets a real module attribute, which takes precedence over this hook.
def _requests() -> ModuleType:
    """Return the ``requests`` module, imported on first use.

    Both call sites below go through this rather than a bare global: a module
    ``__getattr__`` does not fire for name lookups *inside* its own module, and
    ``sys.modules[__name__].requests`` is what lets the suite keep patching
    ``diet_guard._estimator_off.requests``.
    """
    return sys.modules[__name__].requests


def __getattr__(name: str) -> object:
    """Resolve the deferred ``requests`` import on first attribute access."""
    if name != "requests":
        msg = f"module {__name__!r} has no attribute {name!r}"
        raise AttributeError(msg)
    return import_module("requests")


# Open Food Facts nutriment field names (values are "per 100 g").
_OFF_KCAL_FIELD = "energy-kcal_100g"
_OFF_PROTEIN_FIELD = "proteins_100g"
_OFF_CARBS_FIELD = "carbohydrates_100g"
_OFF_FAT_FIELD = "fat_100g"
_GRAMS_PER_REFERENCE = 100.0


def _off_search(term: str) -> list[dict[str, object]]:
    """Query Open Food Facts for products matching ``term``.

    Args:
        term: Free-text food description.

    Returns:
        A list of product dicts (possibly empty), most relevant first.

    Raises:
        requests.RequestException: On any network or HTTP failure.
    """
    params = {
        "q": term,
        "fields": "product_name,nutriments,serving_quantity",
        "page_size": str(OFF_PAGE_SIZE),
    }
    response = _requests().get(
        OFF_SEARCH_URL,
        params=params,
        headers={"User-Agent": OFF_USER_AGENT},
        timeout=OFF_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    payload = response.json()
    if not isinstance(payload, dict):
        return []
    # Search-a-licious returns matches under "hits" (ranked by relevance).
    hits = payload.get("hits", [])
    if not isinstance(hits, list):
        return []
    return [hit for hit in hits if isinstance(hit, dict)]


def _products_with_energy(
    products: list[dict[str, object]],
) -> list[tuple[dict[str, object], dict[str, object]]]:
    """Return the products that carry a usable kcal/100 g value, in order.

    Args:
        products: Product dicts from :func:`_off_search`.

    Returns:
        ``(product, nutriments)`` tuples for every product with a kcal value,
        preserving Open Food Facts' relevance order.
    """
    matches: list[tuple[dict[str, object], dict[str, object]]] = []
    for product in products:
        nutriments = product.get("nutriments")
        if not isinstance(nutriments, dict):
            continue
        if _as_float(nutriments.get(_OFF_KCAL_FIELD)) is not None:
            matches.append((product, nutriments))
    return matches


def _resolve_portion(grams: float | None, product: dict[str, object]) -> float:
    """Decide the portion size, in grams, to use for an estimate.

    Priority: an explicit ``grams`` argument, then the product's Open Food
    Facts serving size, then the configured default.  Keeping ``--grams``
    optional is deliberate: per-entry friction is the whole reason food diaries
    get abandoned, so ``ate "big mac"`` must just work.

    Args:
        grams: Caller-supplied portion, or None.
        product: OFF product dict (may carry ``serving_quantity``).

    Returns:
        A portion size in grams, always greater than zero.
    """
    if grams is not None and grams > 0:
        return float(grams)
    serving = _as_float(product.get("serving_quantity"))
    if serving is not None and serving > 0:
        return serving
    return DEFAULT_PORTION_GRAMS


def _off_nutrition(
    product: dict[str, object],
    nutriments: dict[str, object],
    grams: float | None,
    description: str,
) -> Nutrition:
    """Build a Nutrition for one OFF product, scaled to the chosen portion."""
    portion = _resolve_portion(grams, product)
    factor = portion / _GRAMS_PER_REFERENCE
    name = product.get("product_name")
    label = name if isinstance(name, str) and name.strip() else description
    return Nutrition(
        kcal=round(_scaled(nutriments, _OFF_KCAL_FIELD, factor), 1),
        protein_g=round(_scaled(nutriments, _OFF_PROTEIN_FIELD, factor), 1),
        carbs_g=round(_scaled(nutriments, _OFF_CARBS_FIELD, factor), 1),
        fat_g=round(_scaled(nutriments, _OFF_FAT_FIELD, factor), 1),
        grams=round(portion, 1),
        source=f"openfoodfacts: {label}",
    )


def off_candidates(
    description: str,
    grams: float | None = None,
    limit: int = OFF_PAGE_SIZE,
) -> list[Nutrition]:
    """Return up to ``limit`` Open Food Facts matches for ``description``.

    Returning several candidates (rather than only the top hit) lets the gate
    show alternatives so the user can pick the product that actually matches
    what they ate, instead of silently accepting the first guess.

    Args:
        description: Free-text food description (e.g. ``"big mac"``).
        grams: Portion size in grams; serving size or the default is used when
            None.
        limit: Maximum number of candidates to return.

    Returns:
        Nutrition estimates in OFF relevance order (empty if OFF is unreachable
        or has no usable match).
    """
    try:
        products = _off_search(description)
    except _requests().RequestException as exc:
        _logger.warning("Open Food Facts request failed: %s", exc)
        return []
    return [
        _off_nutrition(product, nutriments, grams, description)
        for product, nutriments in _products_with_energy(products)[:limit]
    ]


def estimate_off(description: str, grams: float | None) -> Nutrition | None:
    """Estimate nutrition for ``description`` via Open Food Facts (top match).

    Args:
        description: Free-text food description (e.g. ``"big mac"``).
        grams: Portion size in grams.  When None, the product's serving size
            is used if known, otherwise the configured default portion.

    Returns:
        The best Nutrition estimate, or None if OFF is unreachable or has no
        usable match (the caller should then fall back to a manual value).
    """
    candidates = off_candidates(description, grams, limit=1)
    return candidates[0] if candidates else None


def _scaled(nutriments: dict[str, object], field: str, factor: float) -> float:
    """Return a per-100 g nutriment scaled to the portion (0 if missing)."""
    per_reference = _as_float(nutriments.get(field))
    if per_reference is None:
        return 0.0
    return per_reference * factor


def estimate(
    description: str,
    *,
    grams: float | None = None,
    manual_kcal: float | None = None,
) -> Nutrition | None:
    """Estimate nutrition for a meal; a manual value takes precedence.

    Args:
        description: Free-text food description.
        grams: Optional portion size in grams.
        manual_kcal: If given, used directly and Open Food Facts is skipped.

    Returns:
        A Nutrition estimate, or None when no manual value was supplied and OFF
        could not produce a usable match.
    """
    if manual_kcal is not None:
        return manual(manual_kcal, grams)
    return estimate_off(description, grams)
