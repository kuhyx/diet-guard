// The single-date dialog: grid state, confirm vs cancel, bounds, month and
// year navigation, keyboard and mouse, spoken labels.

import 'package:diet_guard_app/widgets/pickers/date_dialog.dart';
import 'package:diet_guard_app/widgets/pickers/date_selection.dart';
import 'package:diet_guard_app/widgets/pickers/year_wheel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../label_finders.dart';
import 'picker_test_support.dart';

/// Tuesday 2026-03-10; March 2026 starts on a Sunday.
final _today = DateTime(2026, 3, 10);

DateSelection _sel({DateTime? first, DateTime? last}) => DateSelection.single(
  first: first ?? DateTime(2024),
  last: last ?? DateTime(2027, 12, 31),
  initial: _today,
);

Future<Popped> _open(
  WidgetTester tester,
  DateSelection sel, {
  bool startOnYear = false,
}) => openDialog(
  tester,
  DateDialog(selection: sel, today: _today, startOnYear: startOnYear),
);

void main() {
  testWidgets('Monday first, no header: the 1st of March 2026 sits 7th', (
    tester,
  ) async {
    await _open(tester, _sel());
    final row = tester.getTopLeft(find.byKey(ValueKey(DateTime(2026, 3))));
    final mon = tester.getTopLeft(find.byKey(ValueKey(DateTime(2026, 3, 2))));
    expect(mon.dy, greaterThan(row.dy), reason: 'Monday 2nd starts row 2');
    expect(row.dx, greaterThan(mon.dx + 5 * 30), reason: 'Sunday is last');
  });

  testWidgets('today is ringed, weekends dimmed with a dot', (tester) async {
    await _open(tester, _sel());
    expect(cell(tester, _today).ring, isTrue);
    expect(cell(tester, DateTime(2026, 3, 11)).ring, isFalse);
    expect(cell(tester, DateTime(2026, 3, 14)).dot, isTrue, reason: 'Sat');
    expect(cell(tester, DateTime(2026, 3, 15)).dot, isTrue, reason: 'Sun');
    expect(cell(tester, DateTime(2026, 3, 16)).dot, isFalse);
  });

  testWidgets('a tap highlights; only the check confirms', (tester) async {
    final popped = await _open(tester, _sel());
    await tester.tap(find.byKey(ValueKey(DateTime(2026, 3, 19))));
    await tester.pumpAndSettle();
    expect(popped.closed, isFalse);
    expect(cell(tester, DateTime(2026, 3, 19)).selected, isTrue);
    expect(cell(tester, _today).selected, isFalse);
    await confirm(tester);
    expect(popped.value, DateTime(2026, 3, 19));
  });

  for (final how in ['close icon', 'outside tap', 'Esc']) {
    testWidgets('$how cancels', (tester) async {
      final popped = await _open(tester, _sel());
      await tester.tap(find.byKey(ValueKey(DateTime(2026, 3, 19))));
      await tester.pump();
      switch (how) {
        case 'close icon':
          await tester.tap(controlByLabel('Cancel'));
        case 'outside tap':
          await tester.tapAt(const Offset(4, 4));
        default:
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      }
      await tester.pumpAndSettle();
      expect(popped.closed, isTrue);
      expect(popped.value, isNull);
    });
  }

  testWidgets('out-of-range days and months are dimmed and inert', (
    tester,
  ) async {
    final sel = _sel(first: DateTime(2026, 3, 5), last: DateTime(2026, 4, 20));
    await _open(tester, sel);
    final early = DateTime(2026, 3, 4);
    expect(cell(tester, early).enabled, isFalse);
    await tester.tap(find.byKey(ValueKey(early)));
    await tester.pump();
    expect(sel.start, _today);
    expect(cell(tester, 'month-5').enabled, isFalse);
    await tester.tap(find.byKey(const ValueKey('month-5')));
    await tester.pump();
    expect(sel.month, 3);
    expect(cell(tester, 'month-4').enabled, isTrue);
  });

  testWidgets('a 31st moved to April lands on the 30th', (tester) async {
    final sel = _sel();
    await _open(tester, sel);
    await tester.tap(find.byKey(ValueKey(DateTime(2026, 3, 31))));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('month-4')));
    await tester.pumpAndSettle();
    expect(cell(tester, DateTime(2026, 4, 30)).selected, isTrue);
    await confirm(tester);
    expect(sel.start, DateTime(2026, 4, 30));
  });

  testWidgets('arrows move by a day and a week, Enter confirms', (
    tester,
  ) async {
    final popped = await _open(tester, _sel());
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(cell(tester, DateTime(2026, 3, 18)).selected, isTrue);
    expect(cell(tester, DateTime(2026, 3, 18)).focused, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(popped.value, DateTime(2026, 3, 10));
  });

  testWidgets('a mouse click selects a day', (tester) async {
    final sel = _sel();
    await _open(tester, sel);
    await tester.tap(
      find.byKey(ValueKey(DateTime(2026, 3, 3))),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(sel.start, DateTime(2026, 3, 3));
  });

  testWidgets('the year wheel: mouse drag scrolls, a click selects, no wrap', (
    tester,
  ) async {
    final sel = _sel();
    await _open(tester, sel);
    await tester.drag(
      find.byType(YearWheel),
      const Offset(0, -45),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(sel.year, 2027);
    expect(sel.start, DateTime(2027, 3, 10));
    await tester.tap(
      find.byKey(const ValueKey('wheel-2026')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(sel.year, 2026);
    await tester.drag(find.byType(YearWheel), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(sel.year, 2027, reason: 'the last year; the wheel does not loop');
    await tester.tap(find.byKey(const ValueKey('wheel-2028')));
    await tester.pumpAndSettle();
    expect(sel.year, 2027, reason: '2028 is past lastDate: dimmed, inert');
    await tester.drag(find.byType(YearWheel), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(sel.year, 2024, reason: 'the first year; no wrap to 2027');
  });

  testWidgets('the birth-date flow opens on the year wheel', (tester) async {
    final sel = _sel();
    await _open(tester, sel, startOnYear: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(sel.year, 2025, reason: 'the arrow went to the wheel');
    expect(sel.start, DateTime(2025, 3, 10));
  });

  testWidgets('icons and cells speak; nothing has a tooltip', (tester) async {
    await _open(tester, _sel());
    expect(byIconLabel('Confirm'), findsOneWidget);
    expect(byIconLabel('Cancel'), findsOneWidget);
    expect(bySemLabel('Tuesday, March 10, 2026'), findsOneWidget);
    expect(bySemLabel('Year'), findsOneWidget);
    expect(find.byType(Tooltip), findsNothing);
  });

  testWidgets('a screen reader can tap an in-range day, not an inert one', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _open(tester, _sel(first: DateTime(2026, 3, 5)));
    SemanticsData day(int d) => tester
        .getSemantics(find.byKey(ValueKey(DateTime(2026, 3, d))))
        .getSemanticsData();
    expect(day(12).hasAction(SemanticsAction.tap), isTrue);
    expect(day(4).hasAction(SemanticsAction.tap), isFalse);
    handle.dispose();
  });
}
