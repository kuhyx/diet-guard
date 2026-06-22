import 'dart:io';

import 'package:diet_guard_app/screens/settings_screen.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_secure_storage.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_settings_');
    LogStorageService.resetForTesting(testDir: tempDir);
    FoodBankService.resetForTesting(testDir: tempDir);
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  // SettingsScreen loads its settings via a fire-and-forget Future in
  // initState that Flutter's frame scheduler does not track -- same pitfall
  // as HistoryScreen/LogMealScreen.
  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the kuhyx/diet-guard-sync defaults on a fresh install', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      expect(find.widgetWithText(TextField, 'kuhyx'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'diet-guard-sync'), findsOneWidget);
    });
  });

  testWidgets('Save persists the entered token', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      await tester.enterText(
        find.widgetWithText(TextField, 'Personal access token'),
        'my-pat',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await settle(tester);

      expect(find.text('Saved.'), findsOneWidget);
    });
  });

  testWidgets('Test connection reports success', (tester) async {
    final mock = MockClient(
      (_) async => http.Response('{}', 200),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Test connection'));
      await settle(tester);

      expect(find.text('Connection OK.'), findsOneWidget);
    });
  });

  testWidgets('Test connection reports failure', (tester) async {
    final mock = MockClient((_) async => http.Response('', 403));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Test connection'));
      await settle(tester);

      expect(find.text('Connection failed.'), findsOneWidget);
    });
  });

  testWidgets('Sync now runs a sync tick and reports success', (
    tester,
  ) async {
    final mock = MockClient((req) async {
      if (req.method == 'PUT') return http.Response('{}', 200);
      return http.Response('', 404);
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Sync now'));
      await settle(tester);

      expect(find.text('Synced.'), findsOneWidget);
    });
  });

  testWidgets('Test connection reports a network exception', (tester) async {
    final mock = MockClient((_) async => throw const FormatException('no net'));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Test connection'));
      await settle(tester);

      expect(find.textContaining('Connection failed:'), findsOneWidget);
    });
  });

  testWidgets('Sync now reports a GitHub error', (tester) async {
    final mock = MockClient((_) async => http.Response('boom', 500));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Sync now'));
      await settle(tester);

      expect(find.textContaining('Sync failed:'), findsOneWidget);
    });
  });
}
