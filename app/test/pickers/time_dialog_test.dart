// The time dialog: two looping 24 h wheels, bounds dimmed and inert,
// keyboard, mouse, confirm vs cancel.

import 'package:diet_guard_app/widgets/pickers/time_dialog.dart';
import 'package:diet_guard_app/widgets/pickers/time_wheels.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../label_finders.dart';
import 'picker_test_support.dart';

Future<Popped> _open(
  WidgetTester tester, {
  int initial = 8 * 60,
  int min = 0,
  int max = 1439,
}) => openDialog(
  tester,
  TimeDialog(initialMinute: initial, minMinute: min, maxMinute: max),
);

Finder _wheel(String which) => find.byKey(ValueKey(which));

/// Moves keyboard focus to the minute wheel (the hour wheel has it first).
Future<void> _focusMinutes(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pump();
}

TimeOfDay _value(Popped p) => p.value! as TimeOfDay;

void main() {
  test('hourAllowed and clampMinute', () {
    expect(hourAllowed(7, 480, 1200), isFalse);
    expect(hourAllowed(8, 495, 1200), isTrue);
    expect(hourAllowed(20, 480, 1200), isTrue);
    expect(hourAllowed(21, 480, 1200), isFalse);
    expect(clampMinute(10, 480, 1200), 480);
    expect(clampMinute(1300, 480, 1200), 1200);
  });

  testWidgets('wheels show 24 h numerals and confirm the centre', (
    tester,
  ) async {
    final popped = await _open(tester, initial: 13 * 60 + 5);
    expect(find.byKey(const ValueKey('wheel-13')), findsWidgets);
    expect(find.text('13'), findsWidgets);
    expect(find.text('05'), findsWidgets);
    await confirm(tester);
    expect(_value(popped), const TimeOfDay(hour: 13, minute: 5));
  });

  testWidgets('arrows loop: hour 23 -> 00, minute 59 -> 00', (tester) async {
    final popped = await _open(tester, initial: 23 * 60 + 59);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await _focusMinutes(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_value(popped), const TimeOfDay(hour: 0, minute: 0));
  });

  testWidgets('mouse drag scrolls a wheel; a click selects a number', (
    tester,
  ) async {
    final popped = await _open(tester, initial: 10 * 60);
    await tester.drag(
      _wheel('hour'),
      const Offset(0, -85),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('wheel-58')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await confirm(tester);
    expect(_value(popped), const TimeOfDay(hour: 12, minute: 58));
  });

  testWidgets('out-of-range values are inert; an hour change clamps the '
      'minute into range', (tester) async {
    final popped = await _open(tester, initial: 9 * 60 + 5, min: 8 * 60 + 15);
    // 07 is dimmed: a tap does nothing.
    await tester.tap(find.byKey(const ValueKey('wheel-7')).first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await confirm(tester);
    expect(
      _value(popped),
      const TimeOfDay(hour: 8, minute: 15),
      reason: '09:05 -> 08 pulls :05 up to :15; 07 refused',
    );
  });

  testWidgets('a wheel dragged onto a dimmed value springs back', (
    tester,
  ) async {
    final popped = await _open(tester, initial: 20 * 60, max: 20 * 60);
    await tester.drag(_wheel('hour'), const Offset(0, -85));
    await tester.pumpAndSettle();
    await confirm(tester);
    expect(_value(popped), const TimeOfDay(hour: 20, minute: 0));
  });

  testWidgets('an initial value outside the range opens clamped', (
    tester,
  ) async {
    final popped = await _open(tester, initial: 6 * 60, min: 8 * 60 + 15);
    await confirm(tester);
    expect(_value(popped), const TimeOfDay(hour: 8, minute: 15));
  });

  for (final how in ['close icon', 'outside tap', 'Esc']) {
    testWidgets('$how cancels', (tester) async {
      final popped = await _open(tester);
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

  testWidgets('Enter on the focused close icon cancels', (tester) async {
    final popped = await _open(tester);
    await _focusMinutes(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(popped.closed, isTrue);
    expect(popped.value, isNull);
  });

  testWidgets('wheels speak; no tooltip', (tester) async {
    await _open(tester);
    expect(bySemLabel('Hour'), findsOneWidget);
    expect(bySemLabel('Minute'), findsOneWidget);
    expect(find.byType(Tooltip), findsNothing);
  });
}
