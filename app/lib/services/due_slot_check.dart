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
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/notification_service.dart';

/// Reads the local log, computes today's due-but-unlogged slots as of
/// [now] (defaults to the real clock), and syncs notifications to match.
///
/// [now] is injectable so a test does not depend on the wall-clock hour it
/// happens to run at, the same reason `slot.dart`'s functions are clock-free.
Future<void> checkAndNotify({DateTime? now}) async {
  await LogStorageService.init();
  await NotificationService.init();
  final logged = await LogStorageService.instance.loggedSlotsToday();
  final due = missingSlots(now ?? DateTime.now(), logged);
  await NotificationService.instance.syncToSlots(due);
}
