/// The periodic due/missing-slot check, shared by every platform's scheduler.
///
/// Re-runs the same due/missing-slot logic diet_guard's `_gate.py` uses to
/// decide whether to lock the PC, and syncs notifications to match. Kept in
/// its own library, free of any scheduler plugin, because the two platforms
/// drive it very differently: Android hands it to WorkManager as a real
/// background isolate, while the browser-hosted desktop app can only run it
/// from an in-page timer while its window is open (see
/// `background_tasks_web.dart`).
library;

import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/services/background_sync_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/notification_service.dart';
import 'package:http/http.dart' as http;

/// Reads the local log, computes today's due-but-unlogged slots as of
/// [now] (defaults to the real clock), and syncs notifications to match.
///
/// Pulls from GitHub *only* when a slot looks due, then re-checks -- the
/// local log alone cannot see a meal logged on the PC, so without this the
/// phone re-fires "you haven't logged your 12:00 meal" every background tick
/// until the app is next opened. Deliberately mirrors `_cli_gate._should_lock`
/// on the Python side: cheap local check first, network only when it would
/// change the answer, then decide on the merged result.
///
/// Set [pullWhenDue] false when the caller has just written to the local log
/// itself (the log screen). There the local copy is by definition the freshest
/// thing in existence, so a pull would only duplicate the screen's own
/// auto-sync and delay dismissing the notification.
///
/// [now] is injectable so a test does not depend on the wall-clock hour it
/// happens to run at, the same reason `slot.dart`'s functions are clock-free.
/// [httpClient] is injectable for the same reason [backgroundSyncPush] takes
/// one: the real plugin path only exists in a background isolate on-device.
Future<void> checkAndNotify({
  DateTime? now,
  http.Client? httpClient,
  bool pullWhenDue = true,
}) async {
  await LogStorageService.init();
  final at = now ?? DateTime.now();
  var due = missingSlots(
    at,
    await LogStorageService.instance.loggedSlotsToday(),
  );
  if (pullWhenDue && due.isNotEmpty) {
    // Reuses backgroundSyncPush's settings/isConfigured/try-catch guard rather
    // than reimplementing it: that path is already proven to work from a
    // WorkManager isolate, including the token read and singleton init.
    await backgroundSyncPush(httpClient: httpClient);
    due = missingSlots(at, await LogStorageService.instance.loggedSlotsToday());
  }
  await _reconcileNotifications(due);
}

/// Posts/cancels notifications for [due], swallowing platform failures.
///
/// Best-effort by design, and for both callers: from the log screen the meal
/// is already written by this point and must not be lost to a notification
/// hiccup, and from the WorkManager tick a throw would put the task into a
/// retry-with-backoff loop over something purely cosmetic. `on Object`
/// rather than `on Exception` because `flutter_local_notifications` reports
/// an absent platform channel as a `LateInitializationError`, which is an
/// `Error`.
Future<void> _reconcileNotifications(List<int> due) async {
  try {
    await NotificationService.init();
    await NotificationService.instance.syncToSlots(due);
  } on Object {
    // Notifications are a nicety; nothing above depends on them.
  }
}
