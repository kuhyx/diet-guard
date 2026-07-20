/// WorkManager-backed scheduling, used on Android (and iOS).
library;

import 'dart:io';

import 'package:diet_guard_app/services/background_check_service.dart';
import 'package:diet_guard_app/services/background_sync_service.dart';
import 'package:workmanager/workmanager.dart';

/// True on the two platforms that ship a WorkManager implementation.
///
/// Every entry point below is a no-op elsewhere: registering WorkManager on a
/// platform without it throws, which at app start would mean a blank window.
bool get _hasWorkManager => Platform.isAndroid || Platform.isIOS;

/// Registers the 15-minute periodic due-slot check with the OS.
// coverage:ignore-start
Future<void> initBackgroundTasks() async {
  if (!_hasWorkManager) return;
  await Workmanager().initialize(backgroundCheckCallbackDispatcher);
  await Workmanager().registerPeriodicTask(
    backgroundCheckTaskName,
    backgroundCheckTaskName,
    frequency: const Duration(minutes: 15),
  );
}

/// Queues a connectivity-gated push so a meal logged while offline still
/// uploads on reconnect, without the app being reopened.
///
/// The in-process auto-sync covers the online case; this is the backstop.
/// [ExistingWorkPolicy.replace] coalesces a burst of logs into one pending
/// job, and backoff retries a push that fails once connectivity returns.
Future<void> enqueueSyncBackstop() async {
  if (!_hasWorkManager) return;
  await Workmanager().registerOneOffTask(
    syncPushTaskName,
    syncPushTaskName,
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.replace,
    backoffPolicy: BackoffPolicy.linear,
    backoffPolicyDelay: const Duration(minutes: 1),
  );
}

// coverage:ignore-end
