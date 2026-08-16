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
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:diet_guard_app/services/notification_service.dart';
import 'package:http/http.dart' as http;

/// Reads the local log, computes today's due-but-unlogged slots as of
/// [now] (defaults to the real clock), and syncs notifications to match.
///
/// Syncs on every tick it is asked to ([pullWhenDue], the WorkManager
/// caller's default), then computes due slots from the merged result.
///
/// Deliberately NOT gated on "a slot looks due": for the periodic caller this
/// is the phone's only publish path, mirroring the PC's
/// `diet-guard-sync.timer`.
/// Gating the sync on `due.isNotEmpty` meant that promptly logging every meal
/// on the phone left nothing ever due, so the phone never pushed and the PC
/// kept locking for slots that were already logged -- the exact failure this
/// check exists to prevent. A notification job that happens to sync is not a
/// sync timer.
///
/// Order matters: the sync runs *before* [missingSlots], so a meal pulled from
/// another device suppresses a nag rather than triggering one.
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
  if (pullWhenDue) {
    // Reuses backgroundSyncPush's settings/isConfigured/try-catch guard rather
    // than reimplementing it: that path is already proven to work from a
    // WorkManager isolate, including the token read and singleton init.
    await backgroundSyncPush(httpClient: httpClient);
  }
  // Deliberately not init()ed here: `current` degrades to the default
  // schedule when the singleton is absent, and forcing initialisation would
  // reach path_provider from contexts that have no plugin channel (widget
  // tests, and the WorkManager isolate before main() has run). `main.dart`
  // owns the real init, the same way it does for the other stores.
  final due = missingSlots(
    at,
    await LogStorageService.instance.loggedSlotsToday(),
    MealScheduleService.current,
  );
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
