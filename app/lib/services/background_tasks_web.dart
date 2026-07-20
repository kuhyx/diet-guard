/// In-page scheduling for the browser-hosted desktop app.
///
/// A browser has no equivalent of WorkManager: a closed tab runs nothing, so
/// the due-slot check can only run while the desktop window is open. That is
/// an accepted, deliberate reduction rather than an oversight -- on the PC the
/// real backstop is `diet-guard-gate.timer`, which *locks the screen* on an
/// unlogged slot and is strictly stronger than any notification this app could
/// raise.
library;

import 'dart:async';

import 'package:diet_guard_app/services/due_slot_check.dart';

/// How often the in-page check re-evaluates due slots.
///
/// Five minutes rather than WorkManager's 15: a foreground timer is cheap,
/// and the window is usually open for a short session, so a long period would
/// often mean the check never runs at all.
const inPageCheckInterval = Duration(minutes: 5);

Timer? _timer;

/// Starts the in-page periodic due-slot check (idempotent).
///
/// Runs one check immediately so opening the window is itself a check, then
/// repeats every [inPageCheckInterval] for as long as the page lives.
Future<void> initBackgroundTasks() async {
  if (_timer != null) return;
  _timer = Timer.periodic(inPageCheckInterval, (_) => _runCheck());
  await _runCheck();
}

/// No-op on web: there is no out-of-page scheduler to hand a retry to.
///
/// A push that fails while the window is open is retried by the next
/// foreground sync; one that fails as the window closes is picked up on the
/// next launch.
Future<void> enqueueSyncBackstop() async {}

/// Cancels the in-page timer. Exposed so a test can stop the periodic work it
/// started rather than leaking it into the next test.
void stopBackgroundTasks() {
  _timer?.cancel();
  _timer = null;
}

Future<void> _runCheck() async {
  try {
    await checkAndNotify();
  } on Exception {
    // A failed check must never take the app down: the next tick retries.
  }
}
