/// Shared setup for the food bank screen's split test files.
///
/// `food_bank_screen_test.dart` was one 614-line file; splitting it for the
/// repo's 250-line cap left every part needing the same temp-dir isolation and
/// the same settle helper, so they live here rather than being copy-pasted
/// (which is how two copies drift and one silently stops isolating).
library;

import 'dart:io';

import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Point the food bank and log services at a fresh temp dir per test, and tear
/// it down afterwards. Call once at the top of a file's `main()`.
void useTempFoodBankStores() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_fb_screen_');
    FoodBankService.resetForTesting(store: FileDocumentStore(tempDir));
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
  });

  tearDown(() async {
    FoodBankService.resetForTesting();
    LogStorageService.resetForTesting();
    await tempDir.delete(recursive: true);
  });
}

/// Pump until the screen has finished its untracked initState load.
///
/// FoodBankScreen loads via a fire-and-forget Future in initState that
/// Flutter's frame scheduler does not track, so every test runs inside
/// runAsync() with a short real delay before settling.
Future<void> settle(WidgetTester tester) async {
  await Future<void>.delayed(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}
