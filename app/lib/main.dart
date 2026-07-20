/// App entry point: initializes local storage services, registers the
/// background due-slot check, then shows the primary meal-logging screen.
library;

import 'dart:async';

import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/background_tasks.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/frame_stats.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/notification_service.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LogStorageService.init();
  await AppSettingsService.init();
  await FoodBankService.init();
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
  runApp(const DietGuardApp());
}

/// Root widget for the Diet Guard companion app.
class DietGuardApp extends StatelessWidget {
  /// Creates the [DietGuardApp] root widget.
  const DietGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Diet Guard',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const LogMealScreen(),
    );
  }
}
