/// Due mode versus normal mode on the log screen: what shows, which slot a
/// log lands in, and when the status bar is hidden.
library;

import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/screens/log_meal_due_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/widgets/sync_health_banner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../label_finders.dart';
import 'log_meal_test_support.dart';

final _plain = nutritionForPortion(
  kcal: 100,
  proteinG: 1,
  carbsG: 1,
  fatG: 1,
  perGrams: 0,
  ateGrams: 100,
  source: 'manual',
);

void main() {
  late Future<void> Function() restore;
  late List<bool> statusBar;

  setUp(() async {
    restore = await isolateLogScreenState();
    statusBar = [];
    setStatusBarHidden = ({required hidden}) async => statusBar.add(hidden);
  });
  tearDown(() => restore());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
    await settle(tester);
  }

  Future<void> logTyped(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).at(0), text);
    await settle(tester);
    await tester.tap(controlByLabel('Log meal'));
    await settle(tester);
  }

  testWidgets('due mode strips the bar, banner, date row and chips', (
    tester,
  ) async {
    pinLogMealClock(13);
    await tester.runAsync(() async {
      await open(tester);
      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(SyncHealthBanner), findsNothing);
      expect(find.byIcon(Icons.date_range), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byIcon(Icons.playlist_add_check), findsNothing);
      // What stays: field, six macro fields, the three buttons.
      expect(find.byType(TextField), findsNWidgets(7));
      expect(byIconLabel('Photo'), findsOneWidget);
      expect(byIconLabel('Ask Claude'), findsOneWidget);
      expect(byIconLabel('Log meal'), findsOneWidget);
    });
  });

  testWidgets('normal mode keeps the bar and date row, drops chips and fill', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await open(tester);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byIcon(Icons.date_range), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byIcon(Icons.playlist_add_check), findsNothing);
      expect(byIconLabel('Photo'), findsOneWidget);
      expect(byIconLabel('Ask Claude'), findsOneWidget);
      expect(statusBar, isEmpty, reason: 'normal mode never touches the bar');
    });
  });

  testWidgets('both buttons target the oldest due slot, one after another', (
    tester,
  ) async {
    pinLogMealClock(13); // 08:00 and 12:00 due
    await tester.runAsync(() async {
      await open(tester);
      await logTyped(tester, 'first');
      await logTyped(tester, 'second');
      final slots = (await LogStorageService.instance.todayEntries()).map(
        (e) => e.slotMinute,
      );
      expect(slots, [480, 720]);
    });
  });

  testWidgets('with nothing due the nearest slot is used', (tester) async {
    pinLogMealClock(18); // 16:00 is the latest elapsed slot
    await tester.runAsync(() async {
      for (final minute in [480, 720, 960]) {
        await LogStorageService.instance.logMeal(
          'seed$minute',
          _plain,
          slotMinute: minute,
        );
      }
      await open(tester);
      expect(find.byType(AppBar), findsOneWidget);
      await logTyped(tester, 'late snack');
      final last = (await LogStorageService.instance.todayEntries()).last;
      expect(last.slotMinute, 960);
    });
  });

  testWidgets('the status bar hides in due mode and returns afterwards', (
    tester,
  ) async {
    pinLogMealClock(13);
    await tester.runAsync(() async {
      await open(tester);
      expect(statusBar, [true]);
      await logTyped(tester, 'first');
      expect(statusBar, [true], reason: '12:00 is still due');
      await logTyped(tester, 'second');
      expect(statusBar, [true, false]);
    });
  });

  testWidgets('leaving the screen in due mode restores the status bar', (
    tester,
  ) async {
    pinLogMealClock(13);
    await tester.runAsync(() async {
      await open(tester);
      expect(statusBar, [true]);
      await tester.pumpWidget(const SizedBox());
      expect(statusBar, [true, false]);
    });
  });

  test('the suite default clock is before the first slot', () {
    final now = logMealClock();
    expect(now.hour, 7);
  });
}
