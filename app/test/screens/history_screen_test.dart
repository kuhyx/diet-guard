import 'dart:io';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/screens/photo_viewer_screen.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_history_');
    LogStorageService.resetForTesting(testDir: tempDir);
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  // HistoryScreen loads via a fire-and-forget Future in initState that
  // Flutter's frame scheduler does not track -- see log_meal_screen_test.dart
  // for the same issue. Every test therefore runs inside runAsync() with a
  // short real delay before settling.
  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('shows a message when nothing has been logged', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await settle(tester);

      expect(find.text('Nothing logged yet.'), findsOneWidget);
    });
  });

  testWidgets('lists logged entries newest first, excluding tombstones',
      (tester) async {
    await tester.runAsync(() async {
      await LogStorageService.instance.writeLog({
        '2026-06-01': [
          const FoodEntry(
            id: 'old',
            time: '2026-06-01T08:00:00+02:00',
            desc: 'old breakfast',
            grams: 100,
            kcal: 100,
            proteinG: 5,
            carbsG: 10,
            fatG: 2,
            source: 'manual',
          ),
        ],
        '2026-06-22': [
          const FoodEntry(
            id: 'new',
            time: '2026-06-22T20:00:00+02:00',
            desc: 'new dinner',
            grams: 100,
            kcal: 200,
            proteinG: 10,
            carbsG: 20,
            fatG: 4,
            source: 'manual',
          ),
          const FoodEntry(
            id: 'gone',
            time: '2026-06-22T12:00:00+02:00',
            desc: 'undone lunch',
            grams: 100,
            kcal: 300,
            proteinG: 1,
            carbsG: 1,
            fatG: 1,
            source: 'manual',
            deleted: true,
          ),
        ],
      });

      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await settle(tester);

      expect(find.text('new dinner'), findsOneWidget);
      expect(find.text('old breakfast'), findsOneWidget);
      expect(find.text('undone lunch'), findsNothing);

      final tiles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .toList();
      expect((tiles[0].title! as Text).data, 'new dinner');
      expect((tiles[1].title! as Text).data, 'old breakfast');
    });
  });

  testWidgets('tapping a thumbnail opens the full-screen photo viewer',
      (tester) async {
    await tester.runAsync(() async {
      final imageFile = File('${tempDir.path}/photo.png')
        ..writeAsBytesSync([1, 2, 3]);
      await LogStorageService.instance.writeLog({
        '2026-06-22': [
          FoodEntry(
            id: 'with-photo',
            time: '2026-06-22T20:00:00+02:00',
            desc: 'dinner with a photo',
            grams: 100,
            kcal: 200,
            proteinG: 10,
            carbsG: 20,
            fatG: 4,
            source: 'manual',
            imagePath: imageFile.path,
          ),
        ],
      });

      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await settle(tester);

      await tester.tap(find.byType(Image));
      await settle(tester);

      expect(find.byType(PhotoViewerScreen), findsOneWidget);
    });
  });
}
