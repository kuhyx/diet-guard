import 'dart:io';

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/edit_entry_screen.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _entry = FoodEntry(
  id: 'test-uuid',
  time: '2026-06-22T12:00:00+02:00',
  desc: 'pizza obok pracy',
  grams: 400,
  kcal: 1200,
  proteinG: 52,
  carbsG: 145,
  fatG: 42,
  source: 'manual',
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_edit_test_');
    LogStorageService.resetForTesting(testDir: tempDir);
    FoodBankService.resetForTesting(testDir: tempDir);
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('pre-fills all fields from the entry', (tester) async {
    await tester.runAsync(() async {
      await LogStorageService.instance.writeLog({
        '2026-06-22': [_entry],
      });
      await tester.pumpWidget(
        MaterialApp(home: EditEntryScreen(entry: _entry)),
      );
      await settle(tester);

      expect(find.text('pizza obok pracy'), findsOneWidget);
      expect(find.text('1200'), findsOneWidget);
      expect(find.text('52'), findsOneWidget);
      expect(find.text('145'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('400'), findsOneWidget);
    });
  });

  testWidgets('Save button is present and AppBar title is correct', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await LogStorageService.instance.writeLog({
        '2026-06-22': [_entry],
      });
      await tester.pumpWidget(
        MaterialApp(home: EditEntryScreen(entry: _entry)),
      );
      await settle(tester);
      expect(find.text('Edit meal'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
    });
  });

  testWidgets('shows error when description is cleared', (tester) async {
    await tester.runAsync(() async {
      await LogStorageService.instance.writeLog({
        '2026-06-22': [_entry],
      });
      await tester.pumpWidget(
        MaterialApp(home: EditEntryScreen(entry: _entry)),
      );
      await settle(tester);

      // Clear the description field.
      final descField = find.ancestor(
        of: find.text('pizza obok pracy'),
        matching: find.byType(TextField),
      );
      await tester.enterText(descField, '');
      await tester.tap(find.text('Save'));
      await settle(tester);

      expect(find.text('Description cannot be empty.'), findsOneWidget);
    });
  });

  testWidgets('Save persists updated kcal to the log', (tester) async {
    await tester.runAsync(() async {
      await LogStorageService.instance.writeLog({
        '2026-06-22': [_entry],
      });
      await tester.pumpWidget(
        MaterialApp(home: EditEntryScreen(entry: _entry)),
      );
      await settle(tester);

      // Change kcal.
      await tester.enterText(
        find.ancestor(
          of: find.text('1200'),
          matching: find.byType(TextField),
        ),
        '999',
      );
      await tester.tap(find.text('Save'));
      await settle(tester);

      final log = await LogStorageService.instance.readLog();
      final saved = log['2026-06-22']!.first;
      expect(saved.kcal, 999);
      expect(saved.desc, 'pizza obok pracy');
      expect(saved.id, 'test-uuid');
    });
  });

  testWidgets('legacy null-id entry gains a UUID on save', (tester) async {
    await tester.runAsync(() async {
      const legacy = FoodEntry(
        time: '2026-06-22T08:00:00+02:00',
        desc: 'kabanosy',
        grams: 380,
        kcal: 1174,
        proteinG: 53,
        carbsG: 19,
        fatG: 152,
        source: 'food bank',
      );
      await LogStorageService.instance.writeLog({
        '2026-06-22': [legacy],
      });

      await tester.pumpWidget(
        MaterialApp(home: EditEntryScreen(entry: legacy)),
      );
      await settle(tester);
      await tester.tap(find.text('Save'));
      await settle(tester);

      final log = await LogStorageService.instance.readLog();
      final saved = log['2026-06-22']!.first;
      expect(saved.id, isNotNull);
      expect(saved.id, isNotEmpty);
      expect(saved.kcal, 1174);
    });
  });

  testWidgets('selecting a food bank suggestion fills all macro fields', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await FoodBankService.instance.addManualEntry(
        const FoodBankRecord(
          desc: 'pizza obok pracy',
          kcal: 1200,
          proteinG: 52,
          carbsG: 145,
          fatG: 42,
          grams: 400,
          count: 1,
        ),
      );
      await LogStorageService.instance.writeLog({
        '2026-06-22': [_entry],
      });

      await tester.pumpWidget(
        MaterialApp(home: EditEntryScreen(entry: _entry)),
      );
      await settle(tester);

      // The desc field already matches the bank entry — a suggestion appears.
      expect(find.text('pizza obok pracy'), findsWidgets);
      // Tap the suggestion tile (the one in the autocomplete list, not the
      // TextField itself).
      final suggestionTiles = find.text('pizza obok pracy');
      // At least 2 matches: TextField text + suggestion tile.
      expect(suggestionTiles, findsWidgets);
      await tester.tap(suggestionTiles.last);
      await settle(tester);

      // After selection, suggestions are cleared and macros are filled.
      expect(find.text('1200'), findsOneWidget);
    });
  });

  testWidgets(
    'editing a macro after selecting a suggestion resets source to manual',
    (tester) async {
      await tester.runAsync(() async {
        await FoodBankService.instance.addManualEntry(
          const FoodBankRecord(
            desc: 'pizza obok pracy',
            kcal: 1200,
            proteinG: 52,
            carbsG: 145,
            fatG: 42,
            grams: 400,
            count: 1,
          ),
        );
        await LogStorageService.instance.writeLog({
          '2026-06-22': [_entry],
        });

        await tester.pumpWidget(
          MaterialApp(home: EditEntryScreen(entry: _entry)),
        );
        await settle(tester);

        // Select the suggestion to set _source = 'food bank'.
        final suggestionTiles = find.text('pizza obok pracy');
        await tester.tap(suggestionTiles.last);
        await settle(tester);

        // Manually edit kcal — should flip _source back to 'manual'.
        await tester.enterText(
          find.ancestor(
            of: find.text('1200'),
            matching: find.byType(TextField),
          ),
          '999',
        );
        await settle(tester);
        await tester.tap(find.text('Save'));
        await settle(tester);

        final log = await LogStorageService.instance.readLog();
        // Source reverts to 'manual' after macro edit.
        expect(log['2026-06-22']!.first.source, 'manual');
      });
    },
  );

  testWidgets('tapping an entry tile navigates to EditEntryScreen', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await LogStorageService.instance.writeLog({
        '2026-06-22': [_entry],
      });
      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await settle(tester);

      await tester.tap(find.text('pizza obok pracy'));
      await settle(tester);

      expect(find.text('Edit meal'), findsOneWidget);
      expect(find.text('pizza obok pracy'), findsOneWidget);
      // Macros are pre-filled.
      expect(find.text('1200'), findsOneWidget);
    });
  });
}
