/// Catering auto-log on the log screen: opening it with slots due logs the
/// delivered dishes without a tap (kuhy's override of 2026-11-17).
library;

import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/screens/log_meal_due_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/kuchnia_autolog.dart';
import 'package:diet_guard_app/services/kuchnia_fill.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../label_finders.dart';
import 'log_meal_test_support.dart';

KuchniaDish _dish(int n) => KuchniaDish(
  name: 'Danie $n',
  kcal: 100.0 * n,
  proteinG: 10,
  carbsG: 20,
  fatG: 5,
  grams: 300,
  priority: n,
  slotLabel: '',
  dishId: '${2000 + n}',
);

void main() {
  late Future<void> Function() restore;
  late int fetches;

  setUp(() async {
    restore = await isolateLogScreenState();
    fetches = 0;
    pinLogMealClock(13); // 08:00 and 12:00 due
    KuchniaAutoLog.instance = KuchniaAutoLog(
      fetch: (day) async {
        fetches++;
        return KuchniaRefresh(dishes: [for (var i = 1; i <= 4; i++) _dish(i)]);
      },
      now: () => logMealClock(),
    );
  });
  tearDown(() => restore());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
    await settle(tester);
  }

  testWidgets('opening in due mode logs the due dishes with no tap', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await open(tester);
      final entries = await LogStorageService.instance.todayEntries();
      expect(entries.map((e) => e.desc), ['Danie 1', 'Danie 2']);
      expect(entries.map((e) => e.slotMinute), [480, 720]);
      expect(entries.every((e) => e.source == kuchniaSource), isTrue);
      // A restaurant glyph and an undo per row; nothing is due any more.
      expect(find.byIcon(Icons.restaurant), findsNWidgets(2));
      expect(byIconLabel('Undo'), findsNWidgets(2));
      expect(find.byType(AppBar), findsOneWidget);
    });
  });

  testWidgets('undo removes one dish and a reopen does not log it again', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await open(tester);
      await tester.tap(byIconLabel('Undo').first);
      await settle(tester);
      expect(find.byIcon(Icons.restaurant), findsOneWidget);
      var live = await LogStorageService.instance.todayEntries();
      expect(live.map((e) => e.desc), ['Danie 2']);

      // Reopen: 08:00 is due again, but its tombstoned id blocks the dish.
      await tester.pumpWidget(const SizedBox());
      await open(tester);
      live = await LogStorageService.instance.todayEntries();
      expect(live.map((e) => e.desc), ['Danie 2']);
      expect(find.byIcon(Icons.restaurant), findsNothing);
      expect(find.byType(AppBar), findsNothing, reason: 'still due');
    });
  });

  testWidgets('opening twice fetches once and leaves one entry per dish', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await open(tester);
      await tester.pumpWidget(const SizedBox());
      await open(tester);
      final entries = await LogStorageService.instance.todayEntries();
      expect(entries, hasLength(2));
      expect(fetches, 1);
    });
  });

  testWidgets('normal mode logs nothing and never fetches', (tester) async {
    pinLogMealClock(7);
    await tester.runAsync(() async {
      await open(tester);
      expect(await LogStorageService.instance.todayEntries(), isEmpty);
      expect(fetches, 0);
    });
  });

  testWidgets('resuming into a due slot logs the dishes with no tap', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // Opened before the first slot: normal mode, nothing logged.
      logMealClock = () {
        final t = DateTime.now();
        return DateTime(t.year, t.month, t.day, 7);
      };
      await open(tester);
      expect(await LogStorageService.instance.todayEntries(), isEmpty);
      expect(fetches, 0);

      // Time passes (08:00 and 12:00 elapse); the app comes back to front.
      pinLogMealClock(13);
      final state = tester.state<State<LogMealScreen>>(
        find.byType(LogMealScreen),
      );
      (state as WidgetsBindingObserver).didChangeAppLifecycleState(
        AppLifecycleState.resumed,
      );
      await settle(tester);

      final entries = await LogStorageService.instance.todayEntries();
      expect(entries.map((e) => e.desc), ['Danie 1', 'Danie 2']);
      expect(find.byIcon(Icons.restaurant), findsNWidgets(2));
    });
  });
}
