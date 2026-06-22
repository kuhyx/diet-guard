/// App entry point: initializes local storage services, then shows the
/// primary meal-logging screen.
library;

import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LogStorageService.init();
  await FoodBankService.init();
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
