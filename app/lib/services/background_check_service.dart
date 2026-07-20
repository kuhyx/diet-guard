/// WorkManager wiring for the periodic due-slot check (Android/iOS only).
///
/// Registered as a 15-minute periodic task (WorkManager's periodic floor)
/// rather than four fixed exact alarms -- more robust against OEM
/// background-kill behavior, at the cost of ±15 min precision (accepted; see
/// the project plan). Deliberately **not** requesting `SCHEDULE_EXACT_ALARM`
/// for this reason -- don't reach for it to "fix" perceived lateness.
///
/// The check itself lives in `due_slot_check.dart` so it stays free of the
/// `workmanager` import, which has no web implementation.
library;

import 'package:diet_guard_app/services/background_sync_service.dart';
import 'package:diet_guard_app/services/due_slot_check.dart';
import 'package:workmanager/workmanager.dart';

/// Unique WorkManager task name for the periodic due-slot check.
const String backgroundCheckTaskName = 'diet_guard.background_check';

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
    if (taskName == syncPushTaskName) {
      // Return the push's own success flag so a still-offline / failed push
      // is retried with backoff rather than silently dropped.
      return backgroundSyncPush();
    }
    if (taskName == backgroundCheckTaskName) {
      await checkAndNotify();
    }
    return true;
  });
}

// coverage:ignore-end
