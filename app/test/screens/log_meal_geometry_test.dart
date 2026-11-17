/// Due mode on a real phone's geometry: Pixel-class 1080x2400 at 2.625, with
/// the status-bar and gesture insets and the keyboard open.
///
/// Two promises (kuhy, 2026-11-17): the food field never moves between states,
/// and nothing scrolls with the keyboard up -- the whole form is reachable at
/// once. Heights are asserted, not eyeballed: a form that merely "looks fine"
/// in an unconstrained test viewport is the failure this guards against.
library;

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/claude_relay_client.dart';
import 'package:diet_guard_app/services/claude_relay_fake.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../label_finders.dart';
import 'log_meal_test_support.dart';

void _phone(WidgetTester tester, {required bool keyboard}) {
  tester.view
    ..physicalSize = const Size(1080, 2400)
    ..devicePixelRatio = 2.625
    ..padding = const FakeViewPadding(top: 132, bottom: 63)
    ..viewPadding = const FakeViewPadding(top: 132, bottom: 63)
    ..viewInsets = FakeViewPadding(bottom: keyboard ? 840 : 0);
  addTearDown(tester.view.reset);
}

double _fieldTop(WidgetTester tester) =>
    tester.getTopLeft(find.byType(TextField).at(0)).dy;

double _maxScroll(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position
    .maxScrollExtent;

void main() {
  late Future<void> Function() restore;
  late FakeClaudeRelayClient relay;

  setUp(() async {
    restore = await isolateLogScreenState();
    relay = FakeClaudeRelayClient();
  });
  tearDown(() => restore());

  Future<void> open(WidgetTester tester) async {
    pinLogMealClock(13); // 08:00 and 12:00 are due, so logging one stays due
    await tester.pumpWidget(MaterialApp(home: LogMealScreen(relay: relay)));
    await settle(tester);
  }

  Future<void> fillWorstCase(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).at(0), 'kurczak z ryzem');
    final worst = ['1250', '2400', '1234', '1234', '1234', '1234'];
    for (var i = 0; i < worst.length; i++) {
      await tester.enterText(find.byType(TextField).at(i + 1), worst[i]);
    }
    await settle(tester);
  }

  FoodEntry claudeEntry(String id) => FoodEntry(
    id: id,
    time: DateTime.now().toIso8601String().substring(0, 19),
    desc: 'kurczak z ryzem',
    grams: 300,
    kcal: 540,
    proteinG: 42,
    carbsG: 61,
    fatG: 9,
    source: 'claude',
    slotMinute: 480,
  );

  testWidgets('keyboard open: no scroll, field fixed across every state', (
    tester,
  ) async {
    _phone(tester, keyboard: true);
    await tester.runAsync(() async {
      await open(tester);
      await fillWorstCase(tester);
      final top = _fieldTop(tester);
      expect(_maxScroll(tester), 0, reason: 'idle, worst-case values');

      Future<void> expectSteady(String state) async {
        // A spinner never settles, so pump a few frames instead.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(_fieldTop(tester), top, reason: '$state moved the field');
        expect(_maxScroll(tester), 0, reason: '$state made the form scroll');
      }

      await tester.tap(controlByLabel('Ask Claude'));
      await tester.pump();
      await expectSteady('sending');

      relay.emit(const ClaudeRelayQueued());
      await expectSteady('queued');

      relay.emit(const ClaudeRelayLocked());
      await expectSteady('locked');

      await tester.tap(controlByLabel('Sync is locked'));
      await tester.pump();
      relay.emit(const ClaudeRelayFailed('x'));
      await expectSteady('error');

      await tester.tap(controlByLabel('Claude failed'));
      await tester.pump();
      relay.emit(
        ClaudeRelayLogged(
          claudeEntry(claudeEntryId(relay.sent.last.requestId)),
        ),
      );
      await settle(tester);
      expect(find.byIcon(Icons.undo), findsOneWidget);
      // Still due (12:00 is open): the screen stays in due mode.
      expect(find.byType(AppBar), findsNothing);
      await fillWorstCase(tester);
      await expectSteady('logged row');

      await tester.tap(controlByLabel('Log meal'));
      await settle(tester);
      // Both due slots are logged now: due mode ends, so this is the one
      // transition where the field is allowed to move.
      expect(find.byType(AppBar), findsOneWidget);
      expect(
        (await LogStorageService.instance.todayEntries()).map(
          (e) => e.slotMinute,
        ),
        [480, 720],
      );
    });
  });

  testWidgets('keyboard closed: the form fits too', (tester) async {
    _phone(tester, keyboard: false);
    await tester.runAsync(() async {
      await open(tester);
      await fillWorstCase(tester);
      expect(_maxScroll(tester), 0);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the suggestion block is a fixed height, empty or full', (
    tester,
  ) async {
    _phone(tester, keyboard: true);
    await tester.runAsync(() async {
      await open(tester);
      final empty = tester.getTopLeft(controlByLabel('Ask Claude')).dy;
      await tester.enterText(find.byType(TextField).at(0), 'a');
      await settle(tester);
      expect(tester.getTopLeft(controlByLabel('Ask Claude')).dy, empty);
    });
  });

  testWidgets('the scroll probe sees a squeezed form scroll', (tester) async {
    // Proves the maxScrollExtent == 0 assertions above can fail: a keyboard
    // far taller than a phone's must leave the form scrollable.
    tester.view
      ..physicalSize = const Size(1080, 2400)
      ..devicePixelRatio = 2.625
      ..viewInsets = const FakeViewPadding(bottom: 1800);
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await open(tester);
      expect(_maxScroll(tester), greaterThan(0));
    });
  });
}
