// `checkAndNotify` is the scheduler-independent half of the periodic
// check; `backgroundCheckCallbackDispatcher` itself is integration-only
// (real WorkManager isolate, manual on-device smoke test) per the project
// plan, and is excluded from coverage.

import 'dart:convert';
import 'dart:io';

import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/due_slot_check.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/kuchnia_credential_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:diet_guard_app/services/notification_backend_io.dart';
import 'package:diet_guard_app/services/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_notifications.dart';
import '../fake_secure_storage.dart';

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
    // The due-slot pull reuses backgroundSyncPush, which re-inits these two;
    // pre-seeding the singletons keeps that off the real path_provider
    // channel, exactly as background_sync_service_test.dart does.
    FoodBankService.resetForTesting(store: FileDocumentStore(tempDir));
    AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
    BudgetHistoryService.resetForTesting(
      store: FileDocumentStore(tempDir),
    );
    MealScheduleService.resetForTesting(store: FileDocumentStore(tempDir));
    KuchniaCredentialService.resetForTesting(
      store: FileDocumentStore(tempDir),
    );
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    notificationLog = installFakeAndroidNotifications();
    NotificationService.resetForTesting(
      backend: LocalNotificationsBackend(FlutterLocalNotificationsPlugin()),
    );
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    KuchniaCredentialService.resetForTesting();
    MealScheduleService.resetForTesting();
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
      // Every other id in the 0..23 space is cancelled, not just the other
      // slots of the current schedule -- see syncToSlots' comment.
      expect(cancelled, containsAll(<int>{12, 20}));
      expect(cancelled.intersection(shown), isEmpty);
    },
  );

  test('cancels everything when every due slot is logged', () async {
    await LogStorageService.instance.logMeal('breakfast', _manual, slot: 8);

    await checkAndNotify(now: DateTime(2026, 1, 1, 8));

    expect(notificationLog.where((c) => c.method == 'show'), isEmpty);
    // 24, not 4: syncToSlots sweeps the whole id space so a schedule change
    // cannot orphan the ids it no longer contains.
    expect(notificationLog.where((c) => c.method == 'cancel'), hasLength(24));
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

  test('still syncs when nothing is due', () async {
    await LogStorageService.instance.logMeal('breakfast', _manual, slot: 8);
    SharedPreferences.setMockInitialValues({
      'sync.owner': 'o',
      'sync.repo': 'r',
    });
    installFakeSecureStorage(initial: {'sync.token': 't'});
    var requests = 0;
    final mock = MockClient((req) async {
      requests++;
      return http.Response('', 404);
    });

    await checkAndNotify(now: DateTime(2026, 1, 1, 8), httpClient: mock);

    // Regression guard. This asserted `requests == 0` -- "nothing due, so
    // never touch the network" -- which is precisely the bug: logging every
    // meal promptly on the phone left nothing ever due, so this periodic task
    // never published and the PC kept locking for slots that WERE logged.
    // This is the phone's only unconditional publish path; it must always run.
    expect(requests, greaterThan(0));
  });

  test('pullWhenDue false skips the network even with a slot due', () async {
    SharedPreferences.setMockInitialValues({
      'sync.owner': 'o',
      'sync.repo': 'r',
    });
    installFakeSecureStorage(initial: {'sync.token': 't'});
    var requests = 0;
    final mock = MockClient((req) async {
      requests++;
      return http.Response('', 404);
    });

    await checkAndNotify(
      now: DateTime(2026, 1, 1, 16),
      httpClient: mock,
      pullWhenDue: false,
    );

    expect(requests, 0);
    // Still reconciles notifications from the local log alone.
    expect(
      notificationLog.where((c) => c.method == 'show'),
      isNotEmpty,
    );
  });

  test('a meal pulled from another device cancels its reminder', () async {
    SharedPreferences.setMockInitialValues({
      'sync.owner': 'o',
      'sync.repo': 'r',
    });
    installFakeSecureStorage(initial: {'sync.token': 't'});
    // Must be *today* in the real clock's terms: `now` only steers which
    // slots are due, while "which day's entries count" comes from the
    // system date inside loggedSlotsToday.
    final today = DateTime.now();
    final day =
        '${today.year.toString().padLeft(4, '0')}-'
        '${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';
    // The PC pushed a 12:00 meal this device has never seen locally.
    final remote =
        '{"pc-entry":{"id":"pc-entry","fields":{"body":[{"time":'
        '"${day}T12:30:00+01:00","desc":"pc lunch","kcal":500,'
        '"protein_g":30,"carbs_g":50,"fat_g":15,"grams":300,'
        '"source":"manual","slot":12,"day":"$day"},'
        '"${day}T11:30:00.000Z-0000-pc"]},"deleted":false,'
        '"deleted_hlc":null}}';
    final mock = MockClient((req) async {
      if (req.method == 'PUT') return http.Response('{}', 200);
      if (req.method == 'GET' && req.url.pathSegments.length == 3) {
        return http.Response('{}', 200);
      }
      if (req.url.path.endsWith('/devices')) {
        return http.Response('[{"name":"pc","type":"dir"}]', 200);
      }
      if (req.url.path.endsWith('/devices/pc/food_log.json')) {
        // The Contents API returns base64 in a `content` field, not raw JSON.
        return http.Response(
          jsonEncode({'content': base64.encode(utf8.encode(remote))}),
          200,
        );
      }
      return http.Response('', 404);
    });

    await checkAndNotify(
      now: DateTime(today.year, today.month, today.day, 12),
      httpClient: mock,
    );

    // This is the false alarm the fix exists to kill: 12:00 was unlogged
    // locally, so the pre-fix code fired a reminder for a meal that was
    // already logged on the PC.
    final shown = notificationLog
        .where((c) => c.method == 'show')
        .map((c) => (c.arguments as Map)['id'])
        .toSet();
    expect(shown, isNot(contains(12)));
  });
}
