/// The synced Body document: profile, per-day weights, published workouts.
///
/// Same JSON shape as `~/.local/share/diet_guard/body.json` on the PC (see
/// `docs/DOCS-body.md`). Every field carries its own edit stamp `t`, which is
/// what the sync merge derives its clocks from. Parsing is tolerant: a
/// malformed part is dropped, never raised, so one bad field from a peer
/// cannot take out the rest.
library;

import 'package:diet_guard_app/models/body_entries.dart';

export 'package:diet_guard_app/models/body_entries.dart';

/// Profile field names.
const String profileBirth = 'birth';

/// Profile height field.
const String profileHeight = 'height_cm';

/// Profile sex field (`m` / `f`).
const String profileSex = 'sex';

/// The whole document.
class BodyDocument {
  /// Creates a document.
  const BodyDocument({
    this.profile = const {},
    this.weights = const {},
    this.bodyFat = const {},
    this.steps = const {},
    this.activity,
  });

  /// Parses the local document JSON (already decoded).
  factory BodyDocument.fromJson(Object? raw) {
    if (raw is! Map) return const BodyDocument();
    final profile = <String, Stamped>{};
    final rawProfile = raw['profile'];
    // Every stamped field is kept, known or not: a field a newer peer added
    // (the table prefs were one) must survive this device's re-push.
    if (rawProfile is Map) {
      rawProfile.forEach((name, field) {
        if (name is String && field is Map && field['t'] is String) {
          profile[name] = Stamped(field['v'], field['t'] as String);
        }
      });
    }
    final weights = <String, WeightEntry>{};
    final rawWeights = raw['weights'];
    if (rawWeights is Map) {
      rawWeights.forEach((day, value) {
        final entry = parseWeightValue(value, value is Map ? value['t'] : null);
        if (isDateKey(day) && entry != null) weights[day as String] = entry;
      });
    }
    final bodyFat = <String, BodyFatEntry>{};
    final rawFat = raw['bodyfat'];
    if (rawFat is Map) {
      rawFat.forEach((day, value) {
        final t = value is Map ? value['t'] : null;
        final entry = parseBodyFatValue(value, t);
        if (isDateKey(day) && entry != null) bodyFat[day as String] = entry;
      });
    }
    final steps = <String, StepsEntry>{};
    final rawSteps = raw['steps'];
    if (rawSteps is Map) {
      rawSteps.forEach((day, value) {
        final t = value is Map ? value['t'] : null;
        final entry = parseStepsValue(value, t);
        if (isDateKey(day) && entry != null) steps[day as String] = entry;
      });
    }
    final rawActivity = raw['activity'];
    ActivityData? activity;
    if (rawActivity is Map &&
        rawActivity['sessions'] is List &&
        rawActivity['t'] is String) {
      activity = ActivityData(
        sessions: List<Object?>.from(rawActivity['sessions'] as List),
        t: rawActivity['t'] as String,
      );
    }
    return BodyDocument(
      profile: profile,
      weights: weights,
      bodyFat: bodyFat,
      steps: steps,
      activity: activity,
    );
  }

  /// Profile fields by name.
  final Map<String, Stamped> profile;

  /// Weights by `YYYY-MM-DD`.
  final Map<String, WeightEntry> weights;

  /// Body fat readings by `YYYY-MM-DD`.
  final Map<String, BodyFatEntry> bodyFat;

  /// Steps outside workouts by `YYYY-MM-DD` (written by the phone).
  final Map<String, StepsEntry> steps;

  /// Workouts published by the PC, or null when none ever were.
  final ActivityData? activity;

  /// Returns a copy with the given parts replaced.
  BodyDocument copyWith({
    Map<String, Stamped>? profile,
    Map<String, WeightEntry>? weights,
    Map<String, BodyFatEntry>? bodyFat,
    Map<String, StepsEntry>? steps,
    ActivityData? activity,
  }) => BodyDocument(
    profile: profile ?? this.profile,
    weights: weights ?? this.weights,
    bodyFat: bodyFat ?? this.bodyFat,
    steps: steps ?? this.steps,
    activity: activity ?? this.activity,
  );

  /// JSON form of the local document.
  Map<String, Object?> toJson() => {
    'v': 1,
    'profile': {
      for (final entry in profile.entries)
        entry.key: {'v': entry.value.value, 't': entry.value.t},
    },
    'weights': {
      for (final entry in weights.entries) entry.key: entry.value.toJson(),
    },
    'bodyfat': {
      for (final entry in bodyFat.entries) entry.key: entry.value.toJson(),
    },
    'steps': {
      for (final entry in steps.entries) entry.key: entry.value.toJson(),
    },
    if (activity != null)
      'activity': {'sessions': activity!.sessions, 't': activity!.t},
  };
}
