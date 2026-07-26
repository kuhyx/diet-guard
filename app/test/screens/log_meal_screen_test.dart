import 'dart:io';

import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/screens/calendar_screen.dart';
import 'package:diet_guard_app/screens/food_bank_screen.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/screens/settings_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/widgets/today_progress_card.dart';
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

  testWidgets('logging a manually-typed meal persists it as source manual', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.enterText(find.byType(TextField).at(0), 'toast');
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(2), '150');
      await tester.enterText(find.byType(TextField).at(3), '5');
      await tester.enterText(find.byType(TextField).at(4), '20');
      await tester.enterText(find.byType(TextField).at(5), '3');
      await settle(tester);

      await tester.ensureVisible(logMealButton);
      await tester.tap(logMealButton);
      await settle(tester);

      expect(find.text('Logged "toast".'), findsOneWidget);
      final entries = await LogStorageService.instance.todayEntries();
      expect(entries.single.source, 'manual');
      expect(entries.single.kcal, 150);
    });
  });

  testWidgets('the progress card summarises today after a log', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      expect(find.byType(TodayProgressCard), findsNothing);

      await tester.enterText(find.byType(TextField).at(0), 'toast');
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(2), '150');
      await settle(tester);
      await tester.ensureVisible(logMealButton);
      await tester.tap(logMealButton);
      await settle(tester);

      expect(find.byType(TodayProgressCard), findsOneWidget);
      // Default budget is 2200 with the settings singleton uninitialised.
      expect(find.text('150 / 2200'), findsOneWidget);
      expect(find.text('2050 left'), findsOneWidget);
    });
  });

  testWidgets('typing a new description dismisses the progress card', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.enterText(find.byType(TextField).at(0), 'toast');
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(2), '150');
      await settle(tester);
      await tester.ensureVisible(logMealButton);
      await tester.tap(logMealButton);
      await settle(tester);
      expect(find.byType(TodayProgressCard), findsOneWidget);

      // Starting the next meal clears the previous one's summary, so the
      // card never describes a stale log.
      await tester.enterText(find.byType(TextField).at(0), 'eggs');
      await settle(tester);

      expect(find.byType(TodayProgressCard), findsNothing);
    });
  });

  testWidgets('refuses to log with an empty description', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.ensureVisible(logMealButton);
      await tester.tap(logMealButton);
      await settle(tester);

      expect(find.text('Type what you ate first.'), findsOneWidget);
      expect(await LogStorageService.instance.todayEntries(), isEmpty);
    });
  });

  testWidgets(
    'per-grams and amount-eaten fields scale macros to the eaten portion',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
        await settle(tester);

        await tester.enterText(find.byType(TextField).at(0), 'label food');
        await settle(tester);
        await tester.enterText(find.byType(TextField).at(1), '100');
        await tester.enterText(find.byType(TextField).at(2), '200');
        await tester.enterText(find.byType(TextField).at(3), '10');
        await tester.enterText(find.byType(TextField).at(4), '20');
        await tester.enterText(find.byType(TextField).at(5), '5');
        await tester.enterText(find.byType(TextField).at(6), '150');
        await settle(tester);

        await tester.ensureVisible(logMealButton);
        await tester.tap(logMealButton);
        await settle(tester);

        final entry = (await LogStorageService.instance.todayEntries()).single;
        expect(entry.kcal, 300);
        expect(entry.proteinG, 15);
        expect(entry.carbsG, 30);
        expect(entry.fatG, 7.5);
        expect(entry.grams, 150);
      });
    },
  );

  testWidgets(
    'selecting a food-bank suggestion stamps source food bank, but '
    'editing a macro afterward reverts it to manual',
    (tester) async {
      await tester.runAsync(() async {
        const seed = FoodEntry(
          id: 'seed-1',
          time: '2026-06-01T08:00:00+02:00',
          desc: 'seeded food',
          grams: 100,
          kcal: 250,
          proteinG: 10,
          carbsG: 30,
          fatG: 8,
          source: 'manual',
        );
        await FoodBankService.instance.rebuildAndPersist({
          '2026-06-01': [seed],
        });

        await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
        await settle(tester);

        // The empty-query suggestion list shows the only banked food.
        await tester.tap(find.text('seeded food · 250 kcal'));
        await settle(tester);
        await tester.ensureVisible(logMealButton);
        await tester.tap(logMealButton);
        await settle(tester);

        final firstEntry =
            (await LogStorageService.instance.todayEntries()).single;
        expect(firstEntry.source, 'food bank');
        expect(firstEntry.kcal, 250);

        await tester.tap(find.text('seeded food · 250 kcal'));
        await settle(tester);
        await tester.enterText(find.byType(TextField).at(2), '999');
        await settle(tester);
        await tester.ensureVisible(logMealButton);
        await tester.tap(logMealButton);
        await settle(tester);

        final secondEntry =
            (await LogStorageService.instance.todayEntries()).last;
        expect(secondEntry.source, 'manual');
        expect(secondEntry.kcal, 999);
      });
    },
  );

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
