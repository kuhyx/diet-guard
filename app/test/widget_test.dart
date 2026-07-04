import 'dart:io';

import 'package:diet_guard_app/main.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_app_');
    LogStorageService.resetForTesting(testDir: tempDir);
    FoodBankService.resetForTesting(testDir: tempDir);
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  testWidgets('app launches straight into the meal-logging screen', (
    tester,
  ) async {
    // LogMealScreen's initState does real dart:io file I/O; pumpAndSettle()
    // alone never lets that resolve (see log_meal_screen_test.dart).
    await tester.runAsync(() async {
      await tester.pumpWidget(const DietGuardApp());
      await tester.pumpAndSettle();
    });

    expect(find.text('Diet Guard'), findsOneWidget);
    expect(find.text('What did you eat?'), findsOneWidget);
  });
}
