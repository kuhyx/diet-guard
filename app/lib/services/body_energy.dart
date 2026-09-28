/// The daily calorie target for one chosen goal -- the Body screen's top
/// line: "To **lose** **0.5** **kg** / **week** on **Moderate** eat
/// **2019** kcal". Every bold word is a [Goal] choice, remembered and synced
/// (`body_prefs.dart`). **Informational only**: nothing here writes the
/// budget.
///
/// Port of `diet_guard/_body_energy.py`, gated by the shared
/// `tests/fixtures/body_calc.json`. TDEE is the table BMR x an activity
/// factor, or for a "Measured" choice `BMR x 1.2` plus the real mean daily
/// exercise by that formula. Target = `TDEE -/+ kg per day x 7700`; below
/// the 1200 kcal floor it is flagged, never clamped.
library;

import 'package:diet_guard_app/services/activity_kcal.dart';
import 'package:diet_guard_app/services/body_calc.dart';

/// kcal per kg of body fat.
const double kcalPerKg = 7700;

/// The floor below which a target is flagged.
const int minTargetKcal = 1200;

const double _sedentary = 1.2;

/// A "Measured" choice is `measured:<formula>` (MET, ACSM, Per-km).
const String measuredPrefix = 'measured:';

/// Goal directions, in menu order.
const List<String> directions = ['lose', 'maintain', 'gain'];

/// Offered in the amount picker; any other typed number is accepted too.
const List<double> presetAmounts = [0.25, 0.5, 0.75, 1];

/// Kilograms per weight unit.
const Map<String, double> weightUnits = {
  'kg': 1,
  'lb': 0.45359237,
  'g': 0.001,
  'st': 6.35029318,
};

/// Days per time unit; a month is the mean Gregorian month.
const Map<String, double> timeUnits = {
  'day': 1,
  'week': 7,
  'month': 30.436875,
  'year': 365.2425,
};

/// One selectable activity level and its TDEE multiplier.
class ActivityLevel {
  /// Creates a level.
  const ActivityLevel(this.key, this.label, this.factor, this.meaning);

  /// Stable key.
  final String key;

  /// Display label.
  final String label;

  /// BMR multiplier.
  final double factor;

  /// What the level means, shown in the picker.
  final String meaning;
}

/// Every activity level, in display order.
const List<ActivityLevel> activityLevels = [
  ActivityLevel('sedentary', 'Sedentary', 1.2, 'little or no exercise'),
  ActivityLevel('light', 'Light', 1.375, 'exercise 1-3x a week'),
  ActivityLevel('moderate', 'Moderate', 1.55, 'exercise 3-5x a week'),
  ActivityLevel('very', 'Very active', 1.725, 'exercise 6-7x a week'),
  ActivityLevel('extra', 'Extra active', 1.9, 'training twice a day'),
];

/// Every activity choice, in menu order: the five levels, then measured.
final List<String> activityChoices = [
  for (final level in activityLevels) level.key,
  for (final name in activityFormulas) '$measuredPrefix$name',
];

/// What the user wants: direction, amount per time, at an activity.
class Goal {
  /// Creates a goal.
  const Goal(
    this.direction,
    this.amount,
    this.weightUnit,
    this.timeUnit,
    this.activity,
  );

  /// `lose`, `maintain` or `gain`.
  final String direction;

  /// How much, in [weightUnit] per [timeUnit].
  final double amount;

  /// A [weightUnits] key.
  final String weightUnit;

  /// A [timeUnits] key.
  final String timeUnit;

  /// An [activityChoices] entry.
  final String activity;

  /// Returns a copy with the given parts replaced.
  Goal copyWith({
    String? direction,
    double? amount,
    String? weightUnit,
    String? timeUnit,
    String? activity,
  }) => Goal(
    direction ?? this.direction,
    amount ?? this.amount,
    weightUnit ?? this.weightUnit,
    timeUnit ?? this.timeUnit,
    activity ?? this.activity,
  );

  /// Signed change in kg/day: positive loses, negative gains.
  double kgPerDay() {
    if (direction == 'maintain') return 0;
    final rate = amount * weightUnits[weightUnit]! / timeUnits[timeUnit]!;
    return direction == 'lose' ? rate : -rate;
  }
}

/// The goal until the user picks one.
const Goal defaultGoal = Goal('lose', 0.5, 'kg', 'week', 'moderate');

/// The answer to a [Goal], or why there is none.
class Target {
  /// Creates a target.
  const Target({required this.kcal, required this.tdee, required this.bmrName});

  /// Daily target, or null when the goal needs unpublished measured data.
  final int? kcal;

  /// The maintenance figure it was derived from, when known.
  final double? tdee;

  /// The resting-burn formula the TDEE scales.
  final String bmrName;

  /// Whether the target is under the 1200 kcal floor.
  bool get belowFloor {
    final value = kcal;
    return value != null && value < minTargetKcal;
  }
}

/// Python's `f"{x:g}"`: six significant digits, trailing zeros dropped.
String formatG(double value) {
  if (value == value.truncateToDouble() && value.abs() < 1e15) {
    return value.toInt().toString();
  }
  var text = value.toStringAsPrecision(6);
  if (text.contains('.') && !text.contains('e')) {
    text = text
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
  return text;
}

/// Menu text for an activity choice, e.g. `Measured (ACSM)`.
String activityLabel(String key) {
  if (key.startsWith(measuredPrefix)) {
    return 'Measured (${key.substring(measuredPrefix.length)})';
  }
  for (final level in activityLevels) {
    if (level.key == key) return level.label;
  }
  return key;
}

double? _tdee(double bmr, String activity, Map<String, double>? exercise) {
  if (activity.startsWith(measuredPrefix)) {
    final kcal = exercise?[activity.substring(measuredPrefix.length)];
    return kcal == null ? null : bmr * _sedentary + kcal;
  }
  for (final level in activityLevels) {
    if (level.key == activity) return bmr * level.factor;
  }
  return null;
}

/// The daily kcal that meets [goal] from a [bmr] (kcal/day).
Target goalTarget(
  Goal goal,
  double bmr,
  String bmrName,
  Map<String, double>? exercise,
) {
  final tdee = _tdee(bmr, goal.activity, exercise);
  if (tdee == null) return Target(kcal: null, tdee: null, bmrName: bmrName);
  return Target(
    kcal: halfUp(tdee - goal.kgPerDay() * kcalPerKg).toInt(),
    tdee: tdee,
    bmrName: bmrName,
  );
}
