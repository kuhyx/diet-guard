import 'dart:io';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/screens/settings_screen.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/firebase_backend.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_secure_storage.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_settings_');
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
    FoodBankService.resetForTesting(store: FileDocumentStore(tempDir));
    AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
    BudgetHistoryService.resetForTesting(
      store: FileDocumentStore(tempDir),
    );
    await MealScheduleService.initForTesting(FileDocumentStore(tempDir));
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    MealScheduleService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  // SettingsScreen loads its settings via real (non-fake-clocked) I/O
  // through FileDocumentStore, so every test body runs under
  // tester.runAsync() -- without it, those Futures never get a chance to
  // complete inside TestWidgetsFlutterBinding's fake-clocked zone, and
  // pumpAndSettle spins forever. Also grows the test viewport: the
  // Notifications section pushes earlier fields/buttons below the default
  // 800x600 fold, making them unreachable to tester.tap otherwise.
  Future<void> settle(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the current kcal goal on load', (tester) async {
    await tester.runAsync(() async {
      await AppSettingsService.instance.saveDailyKcalGoal(1800);
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      expect(find.widgetWithText(TextField, '1800'), findsOneWidget);
    });
  });
  testWidgets('shows the derived meal times for the stored schedule', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      // The default schedule still derives the hours that used to be
      // hardcoded, so an existing install sees no change.
      expect(
        find.text('08:00  ·  12:00  ·  16:00  ·  20:00'),
        findsOneWidget,
      );
      expect(find.text('First meal'), findsOneWidget);
      expect(find.text('Last meal'), findsOneWidget);
      expect(find.text('Meals per day'), findsOneWidget);
    });
  });
  testWidgets('reflects a five-meal schedule as the user\'s example', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await MealScheduleService.instance.recordChange(
        const MealSchedule(first: 8, last: 20, count: 5),
      );
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      expect(
        find.text('08:00  ·  11:00  ·  14:00  ·  17:00  ·  20:00'),
        findsOneWidget,
      );
    });
  });
  testWidgets('typing a kcal goal debounces the save', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      await tester.enterText(
        find.widgetWithText(TextField, 'Daily kcal goal'),
        '2100',
      );
      // Immediately after typing, the debounce has not fired yet.
      expect(AppSettingsService.dailyKcalGoal, isNot(2100));

      await Future<void>.delayed(const Duration(milliseconds: 700));
      await tester.pump();
      expect(AppSettingsService.dailyKcalGoal, 2100);
    });
  });
  testWidgets('an invalid kcal goal is not saved', (tester) async {
    await tester.runAsync(() async {
      final initial = AppSettingsService.dailyKcalGoal;
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      await tester.enterText(
        find.widgetWithText(TextField, 'Daily kcal goal'),
        '0',
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await tester.pump();

      expect(AppSettingsService.dailyKcalGoal, initial);
    });
  });
  testWidgets('disposing mid-debounce still flushes the pending goal', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      await tester.enterText(
        find.widgetWithText(TextField, 'Daily kcal goal'),
        '1950',
      );
      // Leave before the 600ms debounce fires. dispose()'s flush fires the
      // persist unawaited (the framework cannot await dispose()), so the
      // in-memory value updates synchronously but the disk write is still a
      // real pending Future -- give it a moment to finish before tearDown
      // deletes the temp dir out from under it.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(AppSettingsService.dailyKcalGoal, 1950);
    });
  });
  testWidgets('tapping Sync settings opens the shared SyncSettingsScreen', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            accountLoader: () async => null,
            sessionProbe: () async => false,
            googleAvailable: false,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('Sync settings'));
      await settle(tester);

      expect(find.text('Firebase sync'), findsOneWidget);
    });
  });
  testWidgets(
    'Sync settings wires storedAccount, not loadAccount, as the '
    'default accountLoader',
    (tester) async {
      // Verifies the read-back fix documented on SettingsScreen.accountLoader:
      // on a device with a stored account and a live session, the shared
      // screen must show it as connected using the injected default, with no
      // fake required to prove the wiring compiles and runs end-to-end.
      await tester.runAsync(() async {
        await saveAccount(
          const FirebaseAccount(email: 'sync@example.com', password: 'pw'),
        );
        await credentialStore().save(
          FirebaseCredentials(
            idToken: 'id',
            refreshToken: 'refresh',
            expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
          ),
        );
        await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
        await settle(tester);

        await tester.tap(find.text('Sync settings'));
        await settle(tester);

        expect(find.text('sync@example.com'), findsOneWidget);
        expect(find.text('Disconnect'), findsOneWidget);
      });
    },
  );
  testWidgets(
    'tapping Advanced sync (GitHub) opens the local GitHubMirrorScreen',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
        await settle(tester);

        await tester.tap(find.text('Advanced sync (GitHub)'));
        await settle(tester);

        expect(find.text('Advanced sync (GitHub)'), findsWidgets);
        expect(find.text('Connect GitHub'), findsOneWidget);
      });
    },
  );
}
