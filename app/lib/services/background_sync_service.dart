/// Connectivity-gated background push: the offline backstop for the
/// immediate-push-on-log behaviour. When a meal is logged while the device is
/// offline the in-process auto-sync fails silently; a WorkManager one-off task
/// with a `NetworkType.connected` constraint (enqueued on every log) fires on
/// reconnect and uploads the log without the app being reopened.
library;

import 'dart:developer';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/firebase_backend.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/github_client_factory.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';
import 'package:diet_guard_app/services/sync_health.dart';
import 'package:diet_guard_app/services/sync_service.dart';
import 'package:diet_guard_app/services/sync_settings.dart';
import 'package:http/http.dart' as http;

/// Unique WorkManager task name for the connectivity-gated push.
const String syncPushTaskName = 'diet_guard.sync_push';

/// Loads sync settings and pushes the local log, returning WorkManager's
/// success flag: `true` when there was nothing to push or the push
/// succeeded, `false` to ask WorkManager to retry (with backoff) after a
/// transient failure -- an offline moment or a GitHub hiccup.
///
/// Extracted from the WorkManager dispatcher so it is unit-testable without
/// the real plugin (which only runs as a background isolate on-device),
/// exactly like [checkAndNotify]. [httpClient] is injectable for the same
/// reason. The service singletons are (re)initialised here because a fresh
/// background isolate has none; [LogStorageService.init] is idempotent, so
/// this is a no-op when a test has already pointed it at a temp dir.
/// [AppSettingsService.init] must run too: [runSync] now also syncs the
/// budget, and applies a merge winner via `AppSettingsService.instance`,
/// which throws if the singleton was never initialised in this isolate.
Future<bool> backgroundSyncPush({http.Client? httpClient}) async {
  // Must run here too, and before anything stamps an HLC: a fresh isolate has
  // its own static state, so without this `currentSyncDeviceId` falls back to
  // the compile-time role constant ('phone') and this tick publishes to
  // `devices/phone/` instead of the persisted uuid. That splits the device
  // across two directories, and because `sync_state` holds a single
  // `pushedRev` with no notion of which identity wrote it, the next
  // *foreground* push then sees `unchanged` and skips writing the uuid
  // directory entirely.
  await initSyncDeviceId();
  await LogStorageService.init();
  await FoodBankService.init();
  await AppSettingsService.init();
  // runSync also merges the budget history through this singleton.
  await BudgetHistoryService.init();
  final SyncSettings settings;
  try {
    settings = await SyncSettings.load();
  } on Exception catch (error, stackTrace) {
    log(
      'diet_guard background sync: cannot read config in-isolate',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
    return false; // let WorkManager retry
  }
  // Either backend counts. `isConfigured` means "has a GitHub token", so
  // gating on it alone silently skips every background push on a device
  // connected only to Firebase.
  if (!settings.isConfigured && await openFirebase() == null) {
    log(
      'diet_guard background sync: no backend configured; nothing to push',
      level: 900,
    );
    await SyncHealth.recordUnconfigured();
    return true; // nothing to push; don't retry
  }
  final client = createGitHubClient(settings, httpClient: httpClient);
  try {
    await runSync(await syncBackend(client));
    await SyncHealth.recordSuccess();
    return true;
  } on Exception catch (error, stackTrace) {
    // Never silent: this is the only signal that a background push failed.
    log(
      'diet_guard background sync failed',
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
    await SyncHealth.recordFailure();
    return false; // offline / transient error -> retry with backoff
  } finally {
    client.close();
  }
}
