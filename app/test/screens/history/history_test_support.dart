/// Shared setup for the history screen's split test files.
///
/// `history_screen_test.dart` was one 1017-line file; splitting it for the
/// repo's 250-line cap left every part needing the same temp-dir isolation and
/// the same settle helper, so they live here rather than being copy-pasted six
/// times (which is how two copies drift and one silently stops isolating).
library;

import 'dart:io';

import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Point the log and budget-history services at a fresh temp dir per test, and
/// tear it down afterwards. Call once at the top of a file's `main()`.
void useTempHistoryStores() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_history_');
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
    BudgetHistoryService.resetForTesting(store: FileDocumentStore(tempDir));
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    await tempDir.delete(recursive: true);
  });
}

/// Pump until the screen has finished its untracked initState load.
///
/// HistoryScreen loads via a fire-and-forget Future in initState that Flutter's
/// frame scheduler does not track -- see log_meal_screen_test.dart for the same
/// issue. Every test therefore runs inside runAsync() with a short real delay
/// before settling.
Future<void> settle(WidgetTester tester) async {
  await Future<void>.delayed(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}
