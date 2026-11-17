/// App entry point: initializes local storage services, registers the
/// background due-slot check, then shows the primary meal-logging screen.
library;

import 'dart:async';

import 'package:crdt_sync_flutter/crdt_sync_flutter.dart'
    show AppErrors, AppErrorsConfig, AppErrorsRouteObserver, installAppErrors;
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/background_tasks.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/claude_relay_client.dart';
import 'package:diet_guard_app/services/claude_relay_firebase.dart';
import 'package:diet_guard_app/services/firebase_client.dart' show openFirebase;
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/frame_stats.dart';
import 'package:diet_guard_app/services/kuchnia_credential_service.dart';
import 'package:diet_guard_app/services/kuchnia_queue.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:diet_guard_app/services/notification_service.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:material_ui/material_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Every error and every wait over 1 s goes to the PC's app-errors ingest,
  // which files a board ticket (kuhyx/utils DOCS-app-errors.md). The release
  // build passes the versionCode and name as dart-defines (release-apk.yml).
  final errors = await installAppErrors(
    const AppErrorsConfig(
      app: 'diet-guard',
      repo: 'kuhyx/diet-guard',
      package: 'diet_guard_app',
      // 0 unless the release build passes --dart-define=APP_BUILD.
      // ignore: avoid_redundant_argument_values
      build: int.fromEnvironment('APP_BUILD'),
      version: String.fromEnvironment('APP_VERSION'),
    ),
  );
  // Before anything that stamps an Hlc or syncs: until this resolves, the
  // device id falls back to the pre-migration role constant.
  final deviceId = await initSyncDeviceId();
  errors.connect(
    sink: () async => (await openFirebase())?.patchValues,
    deviceId: () async => deviceId,
  );
  await LogStorageService.init();
  await AppSettingsService.init();
  await BudgetHistoryService.init();
  await MealScheduleService.init();
  await FoodBankService.init();
  await KuchniaCredentialService.init();
  await BodyService.init();
  await KuchniaQueueService.init();
  // The sparkle button's transport; until this line it fails closed.
  claudeRelay = RtdbClaudeRelay.firebase();
  final notifications = await NotificationService.init();
  // Deliberately *not* awaited before the first frame: the browser's
  // `Notification.requestPermission()` does not complete until the user
  // answers the prompt, so awaiting it here left the desktop app as a blank
  // white window behind the permission bubble. Scheduling is likewise
  // platform-specific (WorkManager on Android, an in-page timer in the
  // browser -- see background_tasks.dart) and equally not worth a delayed
  // first frame.
  // coverage:ignore-start
  unawaited(
    notifications.requestPermission().then((_) {
      return initBackgroundTasks();
    }),
  );
  // coverage:ignore-end
  // Off unless armed with --dart-define=DIET_GUARD_FRAME_STATS=1.
  // coverage:ignore-start
  if (frameStatsEnabled) startFrameStats();
  // coverage:ignore-end
  runApp(DietGuardApp(errors: errors));
}

/// Root widget for the Diet Guard companion app.
class DietGuardApp extends StatelessWidget {
  /// Creates the [DietGuardApp] root widget.
  const DietGuardApp({this.errors, super.key});

  /// App-wide error reporting; null in widget tests.
  final AppErrors? errors;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Diet Guard',
      theme: buildAppTheme(),
      navigatorObservers: [
        if (errors case final errors?) AppErrorsRouteObserver(errors),
      ],
      home: const LogMealScreen(),
    );
  }
}
