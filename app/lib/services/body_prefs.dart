/// The calorie goal the user last picked -- remembered and synced.
///
/// Stored as one extra field, `goal`, on the synced `profile` record (its
/// own stamp: saving it never counts as editing birth, height or sex), so the
/// sentence "To lose 0.5 kg / week on Moderate eat ..." reads the same on
/// the PC gate and the phone. Each part is validated on read: an unknown
/// direction, unit or activity falls back to that part of [defaultGoal].
///
/// Port of `diet_guard/_body_prefs.py`.
library;

import 'package:diet_guard_app/services/body_energy.dart';
import 'package:diet_guard_app/services/body_service.dart';

/// The profile field the goal is stored under.
const String goalField = 'goal';

/// The wire/disk form (short keys).
Map<String, Object> goalToJson(Goal goal) => {
  'dir': goal.direction,
  'amt': goal.amount,
  'wu': goal.weightUnit,
  'tu': goal.timeUnit,
  'act': goal.activity,
};

/// Parses a stored goal part by part, defaulting whatever is unusable.
Goal goalFromJson(Object? raw) {
  if (raw is! Map) return defaultGoal;
  final dir = raw['dir'];
  final amt = raw['amt'];
  final wu = raw['wu'];
  final tu = raw['tu'];
  final act = raw['act'];
  return defaultGoal.copyWith(
    direction: dir is String && directions.contains(dir) ? dir : null,
    amount: amt is num && amt >= 0 ? amt.toDouble() : null,
    weightUnit: wu is String && weightUnits.containsKey(wu) ? wu : null,
    timeUnit: tu is String && timeUnits.containsKey(tu) ? tu : null,
    activity: act is String && activityChoices.contains(act) ? act : null,
  );
}

/// The remembered goal (the default until one is saved).
Goal savedGoal(BodyService body) => goalFromJson(body.profileValue(goalField));

/// Remembers (and syncs) [goal].
Future<void> setGoal(BodyService body, Goal goal) =>
    body.setProfileFields({goalField: goalToJson(goal)});
