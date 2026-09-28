/// Daily steps from Android Health Connect -> the synced Body document.
///
/// The phone is the only writer: it holds the Health Connect permission.
/// Each refresh reads the step intervals of the last [stepsWindowDays] days,
/// **drops every interval overlapping a published workout's `start..end`**
/// (so a recorded walk is not counted as both a workout and steps), sums the
/// rest per local day and stores `steps: {day: {n, t}}`, re-stamping a day
/// only when its count changed -- so an unchanged day re-syncs as a no-op.
///
/// Foreground only: reading in the background isolate needs the extra
/// `READ_HEALTH_DATA_IN_BACKGROUND` permission, which this app does not ask
/// for. And never prompts on its own: [refreshSteps] only reads when the
/// permission is already granted; the Body screen's button asks.
///
/// The platform edge is [StepsSource], picked by the conditional export in
/// `health_steps_source.dart` (Health Connect on Android, nothing on web).
library;

import 'dart:developer';

import 'package:diet_guard_app/models/body_document.dart';
import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/services/activity_kcal.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/health_steps_source.dart';

/// How far back each refresh reads.
const int stepsWindowDays = 28;

/// One Health Connect steps record: [count] steps between [from] and [to].
class StepInterval {
  /// Creates an interval.
  const StepInterval(this.from, this.to, this.count);

  /// Start of the interval.
  final DateTime from;

  /// End of the interval.
  final DateTime to;

  /// Steps taken in it.
  final int count;
}

/// Where step intervals come from.
abstract class StepsSource {
  /// Whether this platform can read steps at all.
  bool get supported;

  /// Whether the read permission is already granted (never prompts).
  Future<bool> hasPermission();

  /// Asks the user for the read permission; true when granted.
  Future<bool> requestPermission();

  /// Every steps record between [from] and [to].
  Future<List<StepInterval>> read(DateTime from, DateTime to);
}

/// The source in use; tests replace it.
StepsSource stepsSource = createStepsSource();

/// Steps per local day, leaving out intervals overlapping any workout.
///
/// Sessions without both `start` and `end` exclude nothing.
Map<String, int> stepsOutsideWorkouts(
  List<StepInterval> intervals,
  List<Session> sessions,
) {
  final windows = [
    for (final session in sessions)
      if (DateTime.tryParse(session.start ?? '') case final start?)
        if (DateTime.tryParse(session.end ?? '') case final end?) (start, end),
  ];
  final byDay = <String, int>{};
  for (final interval in intervals) {
    final overlaps = windows.any(
      (window) =>
          interval.from.isBefore(window.$2) && interval.to.isAfter(window.$1),
    );
    if (overlaps) continue;
    final day = localDateKey(interval.from.toLocal());
    byDay[day] = (byDay[day] ?? 0) + interval.count;
  }
  return byDay;
}

/// Stores [counts], re-stamping only the days whose count changed.
/// Returns whether anything was written.
Future<bool> applySteps(
  BodyService body,
  Map<String, int> counts, {
  DateTime? now,
}) async {
  final steps = Map<String, StepsEntry>.from(body.document.steps);
  final t = isoLocalSeconds(now ?? DateTime.now());
  var changed = false;
  counts.forEach((day, n) {
    if (steps[day]?.n == n) return;
    steps[day] = StepsEntry(n: n, t: t);
    changed = true;
  });
  if (changed) await body.applyMerged(body.document.copyWith(steps: steps));
  return changed;
}

/// Reads Health Connect and stores the daily counts, when permitted.
///
/// Never throws and never prompts: a missing permission, an unsupported
/// platform or a Health Connect error just leaves the stored counts alone.
Future<bool> refreshSteps({DateTime? now}) async {
  final source = stepsSource;
  if (!BodyService.isInitialized || !source.supported) return false;
  try {
    if (!await source.hasPermission()) return false;
    final end = now ?? DateTime.now();
    final start = DateTime(end.year, end.month, end.day - stepsWindowDays);
    final body = BodyService.instance;
    final counts = stepsOutsideWorkouts(
      await source.read(start, end),
      body.sessions ?? const [],
    );
    return await applySteps(body, counts, now: now);
  } on Object catch (error, stackTrace) {
    log(
      'Health Connect steps refresh failed',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  }
}
