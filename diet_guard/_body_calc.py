"""BMI, ideal-weight and resting-metabolism formulas -- pure arithmetic.

Every formula the Body tab shows lives here (and, byte-for-byte, in
``app/lib/services/body_calc.dart``). Nothing here reads a file or a clock:
the caller supplies the person's :class:`~._budget_biometrics.Biometrics`.

Both halves are gated by one shared fixture, ``tests/fixtures/body_calc.json``
(regenerate with ``scripts/build_body_fixture.py``). Rounding goes through
:func:`half_up`, never ``round``: Python's is banker's and Dart's is
half-away-from-zero, so a bare ``round`` would print different numbers on the
two devices for the same person.

Katch-McArdle and Cunningham need a logged body-fat %; until one exists they
come back as ``None`` so the screens can say what is missing.
"""

from __future__ import annotations

from dataclasses import dataclass
import math

from diet_guard._budget_biometrics import Biometrics, mifflin_st_jeor_bmr

__all__ = [
    "BMI_PRIME_NOTE",
    "BROCA_NOTE",
    "KATCH_MCARDLE",
    "TREFETHEN_NOTE",
    "BmiReport",
    "Formula",
    "bmi_report",
    "bmr_formulas",
    "half_up",
    "healthy_range",
    "ideal_summary",
    "ideal_weights",
    "table_bmr",
]

_CM_PER_INCH = 2.54
# The inch-based formulas (Devine, Robinson, Miller, Hamwi) are all
# "base + k per inch over five feet"; below five feet they are undefined.
_FIVE_FEET_IN = 60.0
# Adult BMI categories are WHO's and do not apply to anyone still growing.
ADULT_AGE = 20
# BMI Prime divides by the top of the normal range.
_BMI_PRIME_DIVISOR = 25.0
_HEALTHY_BMI_LOW = 18.5
_HEALTHY_BMI_HIGH = 24.9
_TARGET_BMI = 22.0

# (upper bound exclusive, label), WHO adult classification.
_BMI_BANDS: tuple[tuple[float, str], ...] = (
    (16.0, "severe thinness"),
    (17.0, "moderate thinness"),
    (18.5, "mild thinness"),
    (25.0, "normal"),
    (30.0, "overweight"),
    (35.0, "obese class I"),
    (40.0, "obese class II"),
)
_TOP_BAND = "obese class III"

# Plain-language readings, shown under the numbers on both surfaces.
BMI_PRIME_NOTE = (
    "BMI Prime = BMI / 25: 1.00 is the top of the healthy range, "
    "so 1.02 means 2% above it."
)
TREFETHEN_NOTE = (
    "Trefethen's new BMI = 1.3 x kg / m^2.5: corrects classic BMI, which "
    "over-reads tall people and under-reads short ones."
)
KATCH_MCARDLE = "Katch-McArdle"
BROCA_NOTE = (
    "Broca = height in cm - 100 (1871); it overshoots, so Broca (modified) "
    "takes 10% off it for men and 15% for women."
)


def half_up(value: float, digits: int = 0) -> float:
    """Round ``value`` half-up at ``digits`` decimals, identically to Dart."""
    scale = 10.0**digits
    return math.floor(value * scale + 0.5) / scale


@dataclass(frozen=True)
class Formula:
    """One named formula's result; ``value`` is None when it does not apply."""

    name: str
    value: float | None


@dataclass(frozen=True)
class BmiReport:
    """Body-mass index and its readings.

    Attributes:
        bmi: Classic BMI, kg / m^2.
        prime: BMI divided by 25 (1.0 = top of the normal range).
        trefethen: Trefethen's "new BMI", 1.3 * kg / m^2.5.
        category: WHO adult band, or a note that it does not apply (< 20 y).
    """

    bmi: float
    prime: float
    trefethen: float
    category: str


def _category(bmi: float, age_years: float) -> str:
    """WHO adult band for ``bmi``; under-20s get a note instead."""
    if age_years < ADULT_AGE:
        return "adult categories do not apply under 20"
    for upper, label in _BMI_BANDS:
        if bmi < upper:
            return label
    return _TOP_BAND


def bmi_report(bio: Biometrics) -> BmiReport:
    """Return BMI, BMI Prime, Trefethen's BMI and the WHO category."""
    metres = bio.height_cm / 100.0
    bmi = bio.weight_kg / (metres * metres)
    return BmiReport(
        bmi=bmi,
        prime=bmi / _BMI_PRIME_DIVISOR,
        trefethen=1.3 * bio.weight_kg / metres**2.5,
        category=_category(bmi, bio.age_years),
    )


def _per_inch(
    inches: float, base: float, per_inch: float, *, defined: bool
) -> float | None:
    """``base + per_inch * inches``, or None below five feet."""
    return base + per_inch * inches if defined else None


def ideal_weights(bio: Biometrics) -> tuple[Formula, ...]:
    """Every ideal-body-weight formula we can evaluate, in kg.

    Only Creff uses age -- it is the one that answers "ideal weight for my age
    and height". The BMI healthy range is :func:`healthy_range`, shown with
    BMI rather than here; :func:`ideal_summary` averages these.
    """
    h = bio.height_cm
    inches = h / _CM_PER_INCH - _FIVE_FEET_IN
    ok = inches >= 0
    male = bio.is_male
    metres = h / 100.0
    return (
        Formula("Devine", _per_inch(inches, 50.0 if male else 45.5, 2.3, defined=ok)),
        Formula(
            "Robinson",
            _per_inch(inches, 52.0 if male else 49.0, 1.9 if male else 1.7, defined=ok),
        ),
        Formula(
            "Miller",
            _per_inch(
                inches, 56.2 if male else 53.1, 1.41 if male else 1.36, defined=ok
            ),
        ),
        Formula(
            "Hamwi",
            _per_inch(inches, 48.0 if male else 45.5, 2.7 if male else 2.2, defined=ok),
        ),
        Formula("Broca", h - 100.0),
        Formula("Broca (modified)", (h - 100.0) * (0.9 if male else 0.85)),
        Formula("Lorentz", h - 100.0 - (h - 150.0) / (4.0 if male else 2.0)),
        Formula("Creff (age)", (h - 100.0 + bio.age_years / 10.0) * 0.9),
        Formula(
            "Peterson (BMI 22)", 2.2 * _TARGET_BMI + 3.5 * _TARGET_BMI * (metres - 1.5)
        ),
    )


def healthy_range(bio: Biometrics) -> tuple[float, float]:
    """The weights (kg) at BMI 18.5 and 24.9 for this height."""
    metres = bio.height_cm / 100.0
    return _HEALTHY_BMI_LOW * metres * metres, _HEALTHY_BMI_HIGH * metres * metres


def ideal_summary(formulas: tuple[Formula, ...]) -> tuple[float, float, float] | None:
    """``(average, lowest, highest)`` of the formulas that apply, or None."""
    values = [f.value for f in formulas if f.value is not None]
    if not values:
        return None
    return sum(values) / len(values), min(values), max(values)


def bmr_formulas(
    bio: Biometrics, body_fat_pct: float | None = None
) -> tuple[Formula, ...]:
    """Resting metabolic rate by every formula, kcal/day.

    Katch-McArdle and Cunningham work from lean mass, so they are None until
    a body-fat % is logged. Once one is, Katch-McArdle drives the calorie
    table (:func:`table_bmr`) -- it tracks muscle, which the weight-only
    formulas cannot.
    """
    w, h, a = bio.weight_kg, bio.height_cm, bio.age_years
    if bio.is_male:
        revised = 88.362 + 13.397 * w + 4.799 * h - 5.677 * a
    else:
        revised = 447.593 + 9.247 * w + 3.098 * h - 4.330 * a
    lean = None if body_fat_pct is None else w * (1.0 - body_fat_pct / 100.0)
    return (
        Formula("Mifflin-St Jeor", mifflin_st_jeor_bmr(bio)),
        Formula("Harris-Benedict (revised 1984)", revised),
        Formula(KATCH_MCARDLE, None if lean is None else 370.0 + 21.6 * lean),
        Formula("Cunningham", None if lean is None else 500.0 + 22.0 * lean),
    )


def table_bmr(bio: Biometrics, body_fat_pct: float | None) -> Formula:
    """The BMR the calorie table uses: Katch-McArdle with body fat, else Mifflin."""
    formulas = {f.name: f for f in bmr_formulas(bio, body_fat_pct)}
    if body_fat_pct is not None:
        return formulas[KATCH_MCARDLE]
    return formulas["Mifflin-St Jeor"]
