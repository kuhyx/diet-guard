/// Connectivity-gated background push: the offline backstop for the
/// immediate-push-on-log behaviour. When a meal is logged while the device is
/// offline the in-process auto-sync fails silently; a WorkManager one-off task
/// with a `NetworkType.connected` constraint (enqueued on every log) fires on
/// reconnect and uploads the log without the app being reopened.
library;

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
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
  await LogStorageService.init();
  await FoodBankService.init();
  await AppSettingsService.init();
  final SyncSettings settings;
  try {
    settings = await SyncSettings.load();
  } on Exception {
    return false; // couldn't read config in-isolate; let WorkManager retry
  }
  if (!settings.isConfigured) return true; // nothing to push; don't retry
  final client = GitHubClient(
    owner: settings.owner,
    repo: settings.repo,
    token: settings.token,
    httpClient: httpClient,
  );
  try {
    await runSync(client);
    return true;
  } on Exception {
    return false; // offline / transient GitHub error -> retry with backoff
  } finally {
    client.close();
  }
}
