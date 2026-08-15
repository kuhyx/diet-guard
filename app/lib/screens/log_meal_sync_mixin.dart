import 'dart:async';
import 'dart:developer';

import 'package:diet_guard_app/services/background_tasks.dart';
import 'package:diet_guard_app/services/firebase_client.dart';
import 'package:diet_guard_app/services/github_client_factory.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_health.dart';
import 'package:diet_guard_app/services/sync_service.dart';
import 'package:diet_guard_app/services/sync_settings.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Background-sync and lifecycle behaviour for [LogMealScreen]'s state.
///
/// Split out of `log_meal_screen.dart` for the repo's 250-line cap. It is a
/// mixin rather than a helper class because the behaviour is inseparable from
/// the State it drives: it observes the widget lifecycle, calls `setState`,
/// and reads `mounted`. The screen's own fields stay declared on the State and
/// are reached here through the abstract members below, so the split moves
/// behaviour without moving ownership of the widget's state.
mixin LogMealSyncMixin<T extends StatefulWidget> on State<T>
    implements WidgetsBindingObserver {
  /// Single-flight guard so a launch sync and a lifecycle sync never overlap.
  bool autoSyncing = false;

  /// Latest sync health, driving the "not syncing" banner. Null until read.
  SyncHealthStatus? syncHealth;

  /// The slots that already carry a logged meal today.
  Set<int> loggedSlots = {};

  /// The screen's injected HTTP client, or null to use the default.
  ///
  /// Declared abstract so the mixin stays independent of the widget's own
  /// field: `widget` is typed `T` here, so `widget.httpClient` would not
  /// resolve. The State supplies it.
  http.Client? get syncHttpClient;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pull on resume (catch up on what another device logged while this one
    // was backgrounded) and push on pause (keep the remote near-current).
    final isResumeOrPause =
        state == AppLifecycleState.resumed || state == AppLifecycleState.paused;
    if (isResumeOrPause) {
      unawaited(autoSync());
    }
  }

  /// Best-effort background sync: silent, skips when unconfigured, and never
  /// overlaps itself. Failures are swallowed -- the Settings screen's manual
  /// "Sync now" is where errors get surfaced. The try wraps even loading
  /// [SyncSettings] itself: under `flutter test`, the shared_preferences and
  /// secure-storage platform channels are unmocked by default and throw
  /// [MissingPluginException], which must degrade exactly like "offline"
  /// rather than crash every screen that mounts this widget.
  ///
  /// [refreshSlots] only runs after an actual sync (not on the unconfigured
  /// path, which every existing screen test takes): a fire-and-forget tail
  /// await here can resolve after a *later* test's `tearDown` has already
  /// reset [LogStorageService]'s singleton -- `mounted` alone doesn't bound
  /// that, since widget disposal between tests isn't synchronized with a
  /// still-pending Future from an earlier one.
  Future<void> autoSync() async {
    if (autoSyncing) return;
    autoSyncing = true;
    try {
      final settings = await SyncSettings.load();
      // Either backend counts. `isConfigured` means "has a GitHub token", so
      // gating on it alone silently skips every sync on a device connected
      // only to Firebase -- and once the mirror is retired that is every
      // device. Same fix workout_app's push() already carries.
      if (!settings.isConfigured && await openFirebase() == null) {
        // Never a silent return: an unconfigured device looked exactly like a
        // healthy one with nothing to send, which is how meals sat unpublished
        // for days. Recorded so the banner can say so.
        log(
          'diet_guard auto-sync: no backend configured; nothing to push',
          level: 900,
        );
        await SyncHealth.recordUnconfigured();
        if (mounted) await refreshSyncHealth();
        return;
      }
      final client = createGitHubClient(
        settings,
        httpClient: syncHttpClient,
      );
      try {
        await runSync(await syncBackend(client));
        await SyncHealth.recordSuccess();
      } finally {
        client.close();
      }
      if (!mounted) return;
      await refreshSlots();
      await refreshSyncHealth();
    } on Object catch (error, stackTrace) {
      // Best-effort, but never silent: this swallowed the reason a desktop
      // install could not publish at all, which looked identical to "nothing
      // to sync". Offline and unmocked-platform-channel-under-test both land
      // here too, so it stays non-fatal -- it just says why now.
      log(
        'diet_guard auto-sync failed',
        level: 1000,
        error: error,
        stackTrace: stackTrace,
      );
      await SyncHealth.recordFailure();
      if (mounted) await refreshSyncHealth();
    } finally {
      autoSyncing = false;
    }
  }

  /// Re-reads sync health so the banner reflects the tick that just ran.
  Future<void> refreshSyncHealth() async {
    final status = await SyncHealth.read();
    if (!mounted) return;
    setState(() => syncHealth = status);
  }

  /// Queues the platform's offline push backstop so a meal logged while
  /// offline still uploads on reconnect. The in-process [autoSync] covers
  /// the online case; this is the backstop (a no-op on web, which has no
  /// out-of-page scheduler -- see background_tasks.dart).
  // coverage:ignore-start
  /// Schedules the WorkManager backstop that syncs when the app is closed.
  Future<void> enqueueSyncBackstopTask() => enqueueSyncBackstop();

  // coverage:ignore-end

  /// Re-reads which meal slots are already logged today.
  Future<void> refreshSlots() async {
    final logged = await LogStorageService.instance.loggedSlotsToday();
    if (!mounted) return;
    setState(() => loggedSlots = logged);
  }
}
