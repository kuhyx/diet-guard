/// Pure data helpers behind the Body screen (split out for the 250-line cap).
library;

import 'package:diet_guard_app/services/activity_kcal.dart';
import 'package:diet_guard_app/services/body_calc.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/body_steps.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart' show IconData, Icons;

/// Builds the person from the stored profile and newest weight, or null
/// when anything the formulas need is missing.
Biometrics? currentBiometrics(BodyService body, DateTime today) {
  final birth = DateTime.tryParse(body.birth ?? '');
  final height = body.heightCm;
  final sex = body.sex;
  final weight = body.latestWeight;
  if (birth == null || height == null || sex == null || weight == null) {
    return null;
  }
  return Biometrics(
    weightKg: weight.$2,
    heightCm: height,
    ageYears: ageOn(birth, today).toDouble(),
    isMale: sex == 'm',
  );
}

/// Steps outside workouts by day, as stored.
Map<String, int> stepsByDay(BodyService body) =>
    body.document.steps.map((day, entry) => MapEntry(day, entry.n));

/// Mean daily exercise per formula (steps included), the steps' own share,
/// and the number of full days averaged -- like the PC's `_body_view`: the
/// two means are null without a person, or without any published workout
/// or step count.
(Map<String, double>?, double?, int) bodyExercise(
  BodyService body,
  Biometrics? bio,
  DateTime today,
) {
  final sessions = body.sessions;
  final steps = stepsByDay(body);
  if (bio == null || (sessions == null && steps.isEmpty)) {
    return (null, null, 0);
  }
  final byDay = steps.map((day, n) => MapEntry(day, stepKcal(n, bio)));
  final weight = bio.weightKg;
  final all = sessions ?? const <Session>[];
  return (
    dailyExercise(all, weight, today, byDay),
    extraShare(all, today, byDay),
    windowDays(all, today, byDay),
  );
}

/// Sums each day's non-deleted kcal.
Map<String, double> kcalByDay(DayLog log) => {
  for (final entry in log.entries)
    entry.key: entry.value
        .where((food) => !food.deleted)
        .fold<double>(0, (sum, food) => sum + food.kcal),
};

/// Glyphs of the inputs still missing (profile, weight), in the order the
/// user should supply them; the visible counterpart of [bodyMissingNote].
List<IconData> bodyMissingIcons(BodyService body) => [
  if (body.birth == null || body.heightCm == null || body.sex == null)
    Icons.person,
  if (body.latestWeight == null) Icons.monitor_weight,
];

/// Spoken reason the numbers are missing (screen readers, tests; never
/// painted).
String bodyMissingNote(BodyService body) {
  if (body.latestWeight == null && body.birth == null) {
    return 'Set your profile and enter your weight to see BMI, ideal '
        'weight and calorie targets.';
  }
  if (body.latestWeight == null) return 'Enter your weight to see the numbers.';
  return 'Set your profile (birth date, height, sex) to see the numbers.';
}

/// The age in whole years, or null while no birth date is stored.
String? bodyAgeText(BodyService body, DateTime today) {
  final birth = DateTime.tryParse(body.birth ?? '');
  return birth == null ? null : '${ageOn(birth, today)}';
}
