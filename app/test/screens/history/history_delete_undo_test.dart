import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../label_finders.dart';
import 'history_test_support.dart';

const _entry = FoodEntry(
  id: 'keep-me',
  time: '2026-06-22T12:00:00+02:00',
  desc: 'lentil soup',
  grams: 100,
  kcal: 300,
  proteinG: 15,
  carbsG: 40,
  fatG: 5,
  source: 'manual',
);

void main() {
  useTempHistoryStores();

  testWidgets('delete is immediate and the icon-only undo restores it', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await LogStorageService.instance.writeLog({
        '2026-06-22': [_entry],
      });
      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await settle(tester);
      expect(find.text('lentil soup'), findsOneWidget);

      await tester.tap(byIconLabel('Delete entry'));
      // No confirmation dialog: the row vanishes and a snackbar offers undo.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('lentil soup'), findsNothing);
      expect(bySemLabel('Entry deleted'), findsOneWidget);

      await tester.tap(byIconLabel('Undo'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('lentil soup'), findsOneWidget);

      final stored = await LogStorageService.instance.allEntriesNewestFirst();
      expect(stored.single.id, 'keep-me');
      expect(stored.single.deleted, isFalse);
    });
  });
}
