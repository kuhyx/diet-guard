/// Shared setup for the log screen's due-mode tests.
library;

import 'dart:io';

import 'package:diet_guard_app/screens/log_meal_due_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_logged_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/kuchnia_autolog.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the screen's clock to [hour]:[minute] today for this test only; the
/// suite default (07:00, before the first slot) comes back afterwards.
void pinLogMealClock(int hour, [int minute = 0]) {
  final previous = logMealClock;
  final today = DateTime.now();
  logMealClock = () =>
      DateTime(today.year, today.month, today.day, hour, minute);
  addTearDown(() => logMealClock = previous);
}

/// Points every singleton the screen touches at a fresh temp directory.
///
/// Call from `setUp`; the returned function undoes it, for `tearDown`.
Future<Future<void> Function()> isolateLogScreenState() async {
  final dir = await Directory.systemTemp.createTemp('diet_guard_due_');
  LogStorageService.resetForTesting(store: FileDocumentStore(dir));
  FoodBankService.resetForTesting(store: FileDocumentStore(dir));
  AppSettingsService.resetForTesting(store: FileDocumentStore(dir));
  BudgetHistoryService.resetForTesting(store: FileDocumentStore(dir));
  await MealScheduleService.initForTesting(FileDocumentStore(dir));
  KuchniaAutoLog.instance = KuchniaAutoLog();
  return () async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    MealScheduleService.resetForTesting();
    KuchniaAutoLog.instance = KuchniaAutoLog();
    await dir.delete(recursive: true);
  };
}

/// Lets real file I/O finish, then settles the frame (the screens' file
/// stores run outside the fake-async zone).
Future<void> settle(WidgetTester tester) async {
  await Future<void>.delayed(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

/// Waits for the screen's open-or-resume chain (sync, slots, catering
/// auto-log) to finish, then [settle]s.
Future<void> settleOpen(WidgetTester tester) async {
  final state = tester.state(find.byType(LogMealScreen));
  await (state as LogMealLoggedMixin).openChain;
  await settle(tester);
}

/// [settle]s, then keeps pumping until [done] holds or [timeout] passes.
///
/// For chains a tap starts and nothing exposes: real file I/O outlasts the
/// fixed sleep in [settle] when the machine is loaded.
Future<void> settleUntil(
  WidgetTester tester,
  Future<bool> Function() done, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  await settle(tester);
  while (!await done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
  }
}
