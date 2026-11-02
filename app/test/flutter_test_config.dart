import 'dart:async';

import 'package:diet_guard_app/services/log_feedback.dart';

/// Mutes the log cue suite-wide: audioplayers has no platform side under
/// `flutter test`, so a real play would fail any test that logs a meal.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  LogFeedback.playConfirmCue = () async {};
  await testMain();
}
