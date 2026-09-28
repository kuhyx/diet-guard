/// BMI, ideal-weight and resting-metabolism formulas -- pure arithmetic.
///
/// Byte-for-byte port of `diet_guard/_body_calc.py`, gated by the shared
/// `tests/fixtures/body_calc.json` (`test/services/body_parity_test.dart`).
/// Rounding goes through [halfUp], never `.round()`: Dart rounds half away
/// from zero and Python's `round` is banker's, so the bare builtins would
/// print different numbers on the two devices for the same person.
library;

import 'dart:math' as math;

const double _cmPerInch = 2.54;
const double _fiveFeetIn = 60;

/// Adult BMI categories are WHO's and do not apply to anyone still growing.
const int adultAge = 20;
const double _bmiPrimeDivisor = 25;
const double _healthyBmiLow = 18.5;
const double _healthyBmiHigh = 24.9;
const double _targetBmi = 22;

// (upper bound exclusive, label), WHO adult classification.
const List<(double, String)> _bmiBands = [
  (16, 'severe thinness'),
  (17, 'moderate thinness'),
  (18.5, 'mild thinness'),
  (25, 'normal'),
  (30, 'overweight'),
  (35, 'obese class I'),
  (40, 'obese class II'),
];
const String _topBand = 'obese class III';

/// BMI Prime explained, shown under the numbers on both surfaces.
const String bmiPrimeNote =
    'BMI Prime = BMI / 25: 1.00 is the top of the healthy range, '
    'so 1.02 means 2% above it.';

/// Trefethen's BMI explained, shown under the numbers on both surfaces.
const String trefethenNote =
    "Trefethen's new BMI = 1.3 x kg / m^2.5: corrects classic BMI, which "
    'over-reads tall people and under-reads short ones.';

/// Broca explained, shown under the ideal-weight list.
const String brocaNote =
    'Broca = height in cm - 100 (1871); it overshoots, so Broca (modified) '
    'takes 10% off it for men and 15% for women.';

/// The lean-mass formula the calorie table switches to with a body fat %.
const String katchMcArdle = 'Katch-McArdle';

/// Rounds [value] half-up at [digits] decimals, identically to Python.
double halfUp(double value, [int digits = 0]) {
  final scale = math.pow(10, digits).toDouble();
  return (value * scale + 0.5).floorToDouble() / scale;
}

/// Body metrics that feed every formula.
///
/// Mirrors Python's `_budget_biometrics.Biometrics`.
class Biometrics {
  /// Creates a set of body metrics.
  const Biometrics({
    required this.weightKg,
    required this.heightCm,
    required this.ageYears,
    required this.isMale,
  });

  /// Body mass in kilograms.
  final double weightKg;

  /// Height in centimetres.
  final double heightCm;

  /// Age in completed years.
  final double ageYears;

  /// True for the male constants.
  final bool isMale;
}

/// One named formula's result; [value] is null when it does not apply.
class Formula {
  /// Creates a formula result.
  const Formula(this.name, this.value);

  /// Display name.
  final String name;

  /// The result, or null when undefined for this person.
  final double? value;
}

/// Body-mass index and its readings.
class BmiReport {
  /// Creates a report.
  const BmiReport({
    required this.bmi,
    required this.prime,
    required this.trefethen,
    required this.category,
  });

  /// Classic BMI, kg / m^2.
  final double bmi;

  /// BMI divided by 25.
  final double prime;

  /// Trefethen's "new BMI", 1.3 * kg / m^2.5.
  final double trefethen;

  /// WHO adult band, or a note that it does not apply (< 20 y).
  final String category;
}

/// Mifflin-St Jeor resting metabolic rate, kcal/day.
double mifflinStJeorBmr(Biometrics bio) {
  final base = 10.0 * bio.weightKg + 6.25 * bio.heightCm - 5.0 * bio.ageYears;
  return bio.isMale ? base + 5.0 : base - 161.0;
}

String _category(double bmi, double ageYears) {
  if (ageYears < adultAge) return 'adult categories do not apply under 20';
  for (final (upper, label) in _bmiBands) {
    if (bmi < upper) return label;
  }
  return _topBand;
}

/// Returns BMI, BMI Prime, Trefethen's BMI and the WHO category.
BmiReport bmiReport(Biometrics bio) {
  final metres = bio.heightCm / 100.0;
  final bmi = bio.weightKg / (metres * metres);
  return BmiReport(
    bmi: bmi,
    prime: bmi / _bmiPrimeDivisor,
    trefethen: 1.3 * bio.weightKg / math.pow(metres, 2.5),
    category: _category(bmi, bio.ageYears),
  );
}

double? _perInch(
  double inches,
  double base,
  double perInch, {
  required bool defined,
}) => defined ? base + perInch * inches : null;

/// Every ideal-body-weight formula we can evaluate, in kg.
///
/// Only Creff uses age. The BMI healthy range is [healthyRange], shown with
/// BMI; [idealSummary] averages these.
List<Formula> idealWeights(Biometrics bio) {
  final h = bio.heightCm;
  final inches = h / _cmPerInch - _fiveFeetIn;
  final ok = inches >= 0;
  final male = bio.isMale;
  final metres = h / 100.0;
  return [
    Formula('Devine', _perInch(inches, male ? 50 : 45.5, 2.3, defined: ok)),
    Formula(
      'Robinson',
      _perInch(inches, male ? 52 : 49, male ? 1.9 : 1.7, defined: ok),
    ),
    Formula(
      'Miller',
      _perInch(inches, male ? 56.2 : 53.1, male ? 1.41 : 1.36, defined: ok),
    ),
    Formula(
      'Hamwi',
      _perInch(inches, male ? 48 : 45.5, male ? 2.7 : 2.2, defined: ok),
    ),
    Formula('Broca', h - 100.0),
    Formula('Broca (modified)', (h - 100.0) * (male ? 0.9 : 0.85)),
    Formula('Lorentz', h - 100.0 - (h - 150.0) / (male ? 4.0 : 2.0)),
    Formula('Creff (age)', (h - 100.0 + bio.ageYears / 10.0) * 0.9),
    Formula(
      'Peterson (BMI 22)',
      2.2 * _targetBmi + 3.5 * _targetBmi * (metres - 1.5),
    ),
  ];
}

/// The weights (kg) at BMI 18.5 and 24.9 for this height.
(double, double) healthyRange(Biometrics bio) {
  final metres = bio.heightCm / 100.0;
  return (_healthyBmiLow * metres * metres, _healthyBmiHigh * metres * metres);
}

/// `(average, lowest, highest)` of the formulas that apply, or null.
(double, double, double)? idealSummary(List<Formula> formulas) {
  final values = [for (final f in formulas) ?f.value];
  if (values.isEmpty) return null;
  final sum = values.fold<double>(0, (a, b) => a + b);
  return (
    sum / values.length,
    values.reduce(math.min),
    values.reduce(math.max),
  );
}

/// Resting metabolic rate by every formula, kcal/day.
///
/// Katch-McArdle and Cunningham work from lean mass, so they are null until
/// a body-fat % is logged.
List<Formula> bmrFormulas(Biometrics bio, [double? bodyFatPct]) {
  final w = bio.weightKg;
  final h = bio.heightCm;
  final a = bio.ageYears;
  final revised = bio.isMale
      ? 88.362 + 13.397 * w + 4.799 * h - 5.677 * a
      : 447.593 + 9.247 * w + 3.098 * h - 4.330 * a;
  final lean = bodyFatPct == null ? null : w * (1.0 - bodyFatPct / 100.0);
  return [
    Formula('Mifflin-St Jeor', mifflinStJeorBmr(bio)),
    Formula('Harris-Benedict (revised 1984)', revised),
    Formula(katchMcArdle, lean == null ? null : 370.0 + 21.6 * lean),
    Formula('Cunningham', lean == null ? null : 500.0 + 22.0 * lean),
  ];
}

/// The BMR the calorie table uses: Katch-McArdle with body fat, else Mifflin.
Formula tableBmr(Biometrics bio, double? bodyFatPct) {
  final formulas = bmrFormulas(bio, bodyFatPct);
  return bodyFatPct != null ? formulas[2] : formulas[0];
}

/// Completed years between [birth] and [today].
int ageOn(DateTime birth, DateTime today) {
  var years = today.year - birth.year;
  if (today.month < birth.month ||
      (today.month == birth.month && today.day < birth.day)) {
    years -= 1;
  }
  return years;
}
