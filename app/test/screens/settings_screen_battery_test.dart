import 'dart:io';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/screens/settings_screen.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/firebase_backend.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
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
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
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

  testWidgets('battery exemption button reports a granted status', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            requestBatteryExemption: () async => PermissionStatus.granted,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('Disable battery optimization'));
      await settle(tester);

      expect(find.textContaining('exemption granted'), findsOneWidget);
    });
  });
  testWidgets('battery exemption button reports a denied status', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            requestBatteryExemption: () async => PermissionStatus.denied,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('Disable battery optimization'));
      await settle(tester);

      expect(find.textContaining('not granted'), findsOneWidget);
    });
  });
  testWidgets('battery exemption defaults to the real permission_handler '
      'call, which fails predictably under test', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      await tester.tap(find.text('Disable battery optimization'));
      await settle(tester);

      expect(
        find.textContaining('Could not request exemption'),
        findsOneWidget,
      );
    });
  });
  testWidgets('battery exemption button surfaces a request failure', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            requestBatteryExemption: () async =>
                throw Exception('no permission service'),
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('Disable battery optimization'));
      await settle(tester);

      expect(
        find.textContaining('Could not request exemption'),
        findsOneWidget,
      );
    });
  });
}
