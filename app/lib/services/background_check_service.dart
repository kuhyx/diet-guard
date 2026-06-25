/// WorkManager-driven periodic check: re-runs the same due/missing-slot
/// logic diet_guard's `_gate.py` uses to decide whether to lock the PC, and
/// syncs notifications to match. Registered as a 15-minute periodic task
/// (WorkManager's periodic floor) rather than four fixed exact alarms --
/// more robust against OEM background-kill behavior, at the cost of ±15 min
/// precision (accepted; see the project plan). Deliberately **not**
/// requesting `SCHEDULE_EXACT_ALARM` for this reason -- don't reach for it
/// to "fix" perceived lateness.
library;

import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/notification_service.dart';
import 'package:workmanager/workmanager.dart';

/// Unique WorkManager task name for the periodic due-slot check.
const String backgroundCheckTaskName = 'diet_guard.background_check';

/// Reads the local log, computes today's due-but-unlogged slots as of
/// [now] (defaults to the real clock), and syncs notifications to match.
///
/// Extracted from [backgroundCheckCallbackDispatcher] so this logic is
/// unit-testable without the real WorkManager plugin, which only runs as a
/// true background isolate on-device. [now] is injectable for the same
/// reason `slot.dart`'s functions are clock-free: a test should not depend
/// on the wall-clock hour it happens to run at.
Future<void> checkAndNotify({DateTime? now}) async {
  await LogStorageService.init();
  await NotificationService.init();
  final logged = await LogStorageService.instance.loggedSlotsToday();
  final due = missingSlots(now ?? DateTime.now(), logged);
  await NotificationService.instance.syncToSlots(due);
}

/// WorkManager entry point invoked by the OS on each periodic tick.
///
/// Deliberately thin: all logic lives in [checkAndNotify] so it stays unit
/// testable. This dispatcher itself is integration-only -- manually
/// smoke-tested on-device (see the project plan's verification section),
/// not chased for unit coverage.
// coverage:ignore-start
@pragma('vm:entry-point')
void backgroundCheckCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName == backgroundCheckTaskName) {
      await checkAndNotify();
    }
    return true;
  });
}

// coverage:ignore-end
