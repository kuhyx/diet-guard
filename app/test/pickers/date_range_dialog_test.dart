// The range mode of the date dialog: two taps, shaded span, filled ends,
// the check gated on both taps, presets, restarts and navigation.

import 'package:diet_guard_app/widgets/pickers/date_dialog.dart';
import 'package:diet_guard_app/widgets/pickers/date_selection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'picker_test_support.dart';

DateSelection _sel([DateTimeRange? initial]) => DateSelection.range(
  first: DateTime(2026),
  last: DateTime(2026, 12, 31),
  initial:
      initial ??
      DateTimeRange(start: DateTime(2026, 3, 10), end: DateTime(2026, 3, 10)),
);

Future<Popped> _open(WidgetTester tester, DateSelection sel) =>
    openDialog(tester, DateDialog(selection: sel, today: DateTime(2026, 3)));

Future<void> _tapDay(WidgetTester tester, int day) async {
  await tester.tap(find.byKey(ValueKey(DateTime(2026, 3, day))));
  await tester.pump();
}

void main() {
  testWidgets('two taps: check off after one, span shaded after two', (
    tester,
  ) async {
    final popped = await _open(
      tester,
      DateSelection.range(first: DateTime(2026), last: DateTime(2026, 12, 31)),
    );
    expect(confirmButton(tester).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('month-3')));
    await tester.pump();
    await _tapDay(tester, 4);
    expect(confirmButton(tester).onPressed, isNull, reason: 'one tap');
    expect(cell(tester, DateTime(2026, 3, 4)).selected, isTrue);
    await _tapDay(tester, 9);
    expect(confirmButton(tester).onPressed, isNotNull);
    expect(cell(tester, DateTime(2026, 3, 9)).selected, isTrue, reason: 'cap');
    expect(cell(tester, DateTime(2026, 3, 6)).band, isTrue);
    expect(cell(tester, DateTime(2026, 3, 6)).selected, isFalse);
    expect(cell(tester, DateTime(2026, 3, 10)).band, isFalse);
    await confirm(tester);
    final range = popped.value! as DateTimeRange;
    expect(range.start, DateTime(2026, 3, 4));
    expect(range.end, DateTime(2026, 3, 9));
  });

  testWidgets('later day first still gives an ordered range', (tester) async {
    final popped = await _open(tester, _sel());
    await _tapDay(tester, 20);
    await _tapDay(tester, 12);
    await confirm(tester);
    final range = popped.value! as DateTimeRange;
    expect((range.start.day, range.end.day), (12, 20));
  });

  testWidgets('the same day twice is a valid one-day range', (tester) async {
    final popped = await _open(tester, _sel());
    await _tapDay(tester, 5);
    await _tapDay(tester, 5);
    expect(cell(tester, DateTime(2026, 3, 5)).band, isFalse);
    await confirm(tester);
    final range = popped.value! as DateTimeRange;
    expect(range.start, DateTime(2026, 3, 5));
    expect(range.end, DateTime(2026, 3, 5));
  });

  testWidgets('a third tap restarts and turns the check off', (tester) async {
    await _open(tester, _sel());
    await _tapDay(tester, 2);
    await _tapDay(tester, 6);
    await _tapDay(tester, 25);
    expect(confirmButton(tester).onPressed, isNull);
    expect(cell(tester, DateTime(2026, 3, 25)).selected, isTrue);
    expect(cell(tester, DateTime(2026, 3, 4)).band, isFalse);
  });

  testWidgets('a preset range opens shaded with the check on', (tester) async {
    final sel = _sel(
      DateTimeRange(start: DateTime(2026, 3, 2), end: DateTime(2026, 3, 9)),
    );
    await _open(tester, sel);
    expect(confirmButton(tester).onPressed, isNotNull);
    expect(cell(tester, DateTime(2026, 3, 5)).band, isTrue);
    await tester.tap(find.byKey(const ValueKey('month-7')));
    await tester.pumpAndSettle();
    expect(sel.start, DateTime(2026, 3, 2));
    expect(sel.end, DateTime(2026, 3, 9));
    expect(confirmButton(tester).onPressed, isNotNull);
  });

  testWidgets('keyboard: arrows move the cursor, Space taps, Enter waits '
      'for both ends', (tester) async {
    final popped = await _open(tester, _sel());
    await _tapDay(tester, 10);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(popped.closed, isFalse, reason: 'one end only');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final range = popped.value! as DateTimeRange;
    expect((range.start.day, range.end.day), (10, 12));
  });

  testWidgets('Esc cancels a half-chosen range', (tester) async {
    final popped = await _open(tester, _sel());
    await _tapDay(tester, 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(popped.closed, isTrue);
    expect(popped.value, isNull);
  });
}
