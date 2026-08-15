import 'dart:io';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/calendar_screen.dart';
import 'package:diet_guard_app/screens/food_bank_screen.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/screens/settings_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Stub launcher that records the URL instead of opening it -- same pattern
/// as settings_screen_test.dart's fake, duplicated locally per this
/// codebase's convention of small per-file fakes over a shared mock.
class _FakeUrlLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  String? launched;

  @override
  final LinkDelegate? linkDelegate = null;

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched = url;
    return true;
  }
}

/// Returns a fixed [XFile] without touching any real platform channel.

/// A minimal valid 1x1 transparent PNG, so the thumbnail preview can decode
/// it as a real image instead of throwing on bogus bytes.

void main() {

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_screen_');
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
    FoodBankService.resetForTesting(store: FileDocumentStore(tempDir));
    AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
    BudgetHistoryService.resetForTesting(
      store: FileDocumentStore(tempDir),
    );
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  final logMealButton = find.byTooltip('Log meal');

  // The screen's button handlers and description-field listener trigger
  // real `dart:io` file I/O as fire-and-forget Futures that Flutter's frame
  // scheduler does not track -- pumpAndSettle() can return *before* that
  // I/O (and its eventual setState) actually finishes. Every interaction
  // that can reach a service call therefore runs inside a single
  // tester.runAsync() per test, with a short real delay before each
  // pumpAndSettle() to let the in-flight I/O actually complete first.
  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('the history icon navigates to HistoryScreen', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.history));
      await settle(tester);

      expect(find.byType(HistoryScreen), findsOneWidget);
    });
  });
  testWidgets('the calendar icon navigates to CalendarScreen', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.calendar_month));
      await settle(tester);

      expect(find.byType(CalendarScreen), findsOneWidget);
    });
  });
  testWidgets('the settings icon navigates to SettingsScreen', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      // SettingsScreen briefly shows a perpetually-animating
      // CircularProgressIndicator while its settings load; pumpAndSettle
      // never settles against that, so pump explicit frames instead (see
      // history_screen_test.dart's note on the same pitfall).
      await tester.tap(find.byIcon(Icons.settings));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();

      expect(find.byType(SettingsScreen), findsOneWidget);
    });
  });
  testWidgets('food bank icon navigates to FoodBankScreen', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.restaurant_menu));
      await settle(tester);

      expect(find.byType(FoodBankScreen), findsOneWidget);
    });
  });
  testWidgets('logged slot chip renders check-icon avatar', (tester) async {
    await tester.runAsync(() async {
      final now = DateTime.now();
      final dateKey =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final at8 = DateTime(now.year, now.month, now.day, 8);

      await LogStorageService.instance.writeLog({
        dateKey: [
          FoodEntry(
            id: 'slot-seed',
            time: at8.toIso8601String(),
            desc: 'breakfast',
            grams: 100,
            kcal: 300,
            proteinG: 10,
            carbsG: 40,
            fatG: 5,
            source: 'manual',
            slot: 8,
          ),
        ],
      });

      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      // The 08:00 slot is logged — its ChoiceChip has a check-icon avatar.
      expect(find.byIcon(Icons.check), findsWidgets);
    });
  });
  testWidgets('tapping a slot chip selects it', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      // Tap the 08:00 chip to force _selectedSlot = 8.
      await tester.tap(find.text('08:00'));
      await settle(tester);

      final chip = tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text('08:00'),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(chip.selected, isTrue);
    });
  });
}
