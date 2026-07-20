// `checkAndNotify` is the scheduler-independent half of the periodic
// check; `backgroundCheckCallbackDispatcher` itself is integration-only
// (real WorkManager isolate, manual on-device smoke test) per the project
// plan, and is excluded from coverage.

import 'dart:io';

import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/services/due_slot_check.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/notification_backend_io.dart';
import 'package:diet_guard_app/services/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_notifications.dart';

const _manual = Nutrition(
  kcal: 200,
  proteinG: 10,
  carbsG: 20,
  fatG: 5,
  grams: 100,
  source: 'manual',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  late List<MethodCall> notificationLog;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_bg_check_');
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
    notificationLog = installFakeAndroidNotifications();
    NotificationService.resetForTesting(
      backend: LocalNotificationsBackend(FlutterLocalNotificationsPlugin()),
    );
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    NotificationService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  test(
    'shows due-and-unlogged slots, cancels logged and upcoming ones',
    () async {
      await LogStorageService.instance.logMeal('lunch', _manual, slot: 12);

      await checkAndNotify(now: DateTime(2026, 1, 1, 16));

      final shown = notificationLog
          .where((c) => c.method == 'show')
          .map((c) => (c.arguments as Map)['id'])
          .toSet();
      final cancelled = notificationLog
          .where((c) => c.method == 'cancel')
          .map((c) => (c.arguments as Map)['id'])
          .toSet();
      expect(shown, {8, 16});
      expect(cancelled, {12, 20});
    },
  );

  test('cancels everything when every due slot is logged', () async {
    await LogStorageService.instance.logMeal('breakfast', _manual, slot: 8);

    await checkAndNotify(now: DateTime(2026, 1, 1, 8));

    expect(notificationLog.where((c) => c.method == 'show'), isEmpty);
    expect(notificationLog.where((c) => c.method == 'cancel'), hasLength(4));
  });

  test('uses the real clock when now is omitted', () async {
    // Just exercises the `now ?? DateTime.now()` branch without asserting
    // on specific slots (which depend on the actual time the test runs).
    await checkAndNotify();
    expect(
      notificationLog.where(
        (c) => c.method == 'show' || c.method == 'cancel',
      ),
      isNotEmpty,
    );
  });
}
