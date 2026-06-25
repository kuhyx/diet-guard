/// App entry point: initializes local storage services, registers the
/// background due-slot check, then shows the primary meal-logging screen.
library;

import 'dart:io';

import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/background_check_service.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LogStorageService.init();
  await FoodBankService.init();
  final notifications = await NotificationService.init();
  await notifications.requestPermission();
  // WorkManager has no Linux/web/desktop implementation -- registering it
  // there throws. Guard to the two platforms that ship it.
  // coverage:ignore-start
  if (Platform.isAndroid || Platform.isIOS) {
    await Workmanager().initialize(backgroundCheckCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      backgroundCheckTaskName,
      backgroundCheckTaskName,
      frequency: const Duration(minutes: 15),
    );
  }
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
