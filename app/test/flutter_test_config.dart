import 'dart:async';

import 'package:diet_guard_app/screens/log_meal_due_mixin.dart';
import 'package:diet_guard_app/services/log_feedback.dart';

/// Suite-wide test defaults.
///
/// * The log cue is muted: audioplayers has no platform side under
///   `flutter test`, so a real play would fail any test that logs a meal.
/// * The log screen's clock is pinned to 07:00 today, before the first slot,
///   so no slot is due and the screen is in normal mode whatever the wall
///   clock says. Without the pin every nav and slot test would pass at night
///   and fail by day, once due mode hides the app bar. A test that needs due
///   mode sets [logMealClock] itself.
/// * The status bar call goes nowhere; a test that checks it replaces the hook.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  LogFeedback.playConfirmCue = () async {};
  logMealClock = () {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, 7);
  };
  setStatusBarHidden = ({required hidden}) async {};
  await testMain();
}
