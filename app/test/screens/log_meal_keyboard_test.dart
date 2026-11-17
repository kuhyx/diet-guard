/// kuhy's hard rule, 2026-11-17: NO COVER BY KEYBOARD EVER. With the keyboard
/// open the today-progress card and the logged rows collapse, so the field,
/// suggestions, macro fields and action row all sit above it with no scroll.
/// Also the date picker's move into the app bar and its picked-date tint.
library;

import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/widgets/logged_meal_row.dart';
import 'package:diet_guard_app/widgets/meal_action_row.dart';
import 'package:diet_guard_app/widgets/today_progress_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../label_finders.dart';
import 'log_meal_test_support.dart';

const double _dpr = 2.625;

void _phone(WidgetTester tester, {required double keyboardPx}) {
  tester.view
    ..physicalSize = const Size(1080, 2400)
    ..devicePixelRatio = _dpr
    ..padding = const FakeViewPadding(top: 132, bottom: 63)
    ..viewPadding = const FakeViewPadding(top: 132, bottom: 63)
    ..viewInsets = FakeViewPadding(bottom: keyboardPx);
}

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

/// Every widget the form shows ends above the keyboard, the action row is
/// tappable, and nothing scrolls.
void _expectAboveKeyboard(WidgetTester tester, double keyboardPx) {
  final keyboardTop = (2400 - keyboardPx) / _dpr;
  for (final type in <Type>[
    TextField,
    MealActionRow,
    LoggedMealRow,
    TodayProgressCard,
  ]) {
    for (final e in find.byType(type).evaluate()) {
      final box = e.renderObject! as RenderBox;
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      expect(bottom, lessThanOrEqualTo(keyboardTop), reason: '$type covered');
    }
  }
  expect(controlByLabel('Log meal').hitTestable(), findsOneWidget);
  expect(controlByLabel('Photo').hitTestable(), findsOneWidget);
  expect(_maxScroll(tester), 0, reason: 'the form scrolls');
}

void main() {
  late Future<void> Function() restore;
  setUp(() async => restore = await isolateLogScreenState());
  tearDown(() => restore());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
    await settle(tester);
  }

  Future<void> fillWorstCase(WidgetTester tester, String name) async {
    await tester.enterText(find.byType(TextField).at(0), name);
    final worst = ['1250', '2400', '1234', '1234', '1234', '1234'];
    for (var i = 0; i < worst.length; i++) {
      await tester.enterText(find.byType(TextField).at(i + 1), worst[i]);
    }
    await settle(tester);
  }

  for (final kb in [840.0, 1050.0]) {
    testWidgets('normal mode, keyboard $kb px: nothing under it', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      _phone(tester, keyboardPx: 0);
      await tester.runAsync(() async {
        await open(tester);
        await fillWorstCase(tester, 'kurczak z ryzem');
        await tester.tap(controlByLabel('Log meal'));
        await settle(tester);
        // Keyboard closed: the card and the logged row are both there.
        expect(find.byType(TodayProgressCard), findsOneWidget);
        expect(find.byType(LoggedMealRow), findsOneWidget);

        _phone(tester, keyboardPx: kb);
        await fillWorstCase(tester, 'kurczak');
        expect(find.byType(TodayProgressCard), findsNothing);
        expect(find.byType(LoggedMealRow), findsNothing);
        _expectAboveKeyboard(tester, kb);

        _phone(tester, keyboardPx: 0);
        await settle(tester);
        expect(find.byType(LoggedMealRow), findsOneWidget);
      });
    });

    testWidgets('due mode, keyboard $kb px: nothing under it', (tester) async {
      addTearDown(tester.view.reset);
      _phone(tester, keyboardPx: kb);
      pinLogMealClock(13);
      await tester.runAsync(() async {
        await open(tester);
        await fillWorstCase(tester, 'kurczak z ryzem');
        expect(find.byType(AppBar), findsNothing);
        _expectAboveKeyboard(tester, kb);
      });
    });
  }

  group('date picker in the app bar', () {
    Color tint(WidgetTester tester) {
      final icon = find.byIcon(Icons.edit_calendar);
      return tester.widget<Icon>(icon).color ??
          IconTheme.of(tester.element(icon)).color!;
    }

    testWidgets('leftmost action; no row above the field', (tester) async {
      await tester.runAsync(() async {
        await open(tester);
        final date = find.byIcon(Icons.edit_calendar);
        expect(
          find.descendant(of: find.byType(AppBar), matching: date),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.date_range), findsNothing);
        final x = tester.getCenter(date).dx;
        for (final other in [Icons.monitor_weight, Icons.settings]) {
          expect(x, lessThan(tester.getCenter(find.byIcon(other)).dx));
        }
      });
    });

    testWidgets('a picked future date tints the icon gold with a dot', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await open(tester);
        final gold = Theme.of(
          tester.element(find.byType(AppBar)),
        ).colorScheme.primary;
        const badge = ValueKey<String>('log-date-badge');
        expect(tint(tester), isNot(gold));
        expect(find.byKey(badge), findsNothing);

        await tester.tap(controlByLabel('Log for later'));
        await settle(tester);
        await tester.tap(controlByLabel('Confirm'));
        await settle(tester);
        expect(tint(tester), gold);
        expect(find.byKey(badge), findsOneWidget);
        final dates = find.textContaining(RegExp(r'^\d{4}-\d{2}-\d{2}$'));
        expect(dates, findsNothing, reason: 'no painted date');

        await tester.tap(controlByLabel('Back to today'));
        await settle(tester);
        expect(find.byKey(badge), findsNothing);
      });
    });
  });
}
