import 'package:diet_guard_app/models/day_status.dart';
import 'package:diet_guard_app/widgets/day_status_calendar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

Color _colorOfDay(WidgetTester tester, String day) {
  final container = tester.widget<Container>(
    find.ancestor(of: find.text(day), matching: find.byType(Container)).first,
  );
  final decoration = container.decoration! as BoxDecoration;
  return decoration.color!;
}

void main() {
  group('DayStatusCalendar', () {
    final june2026 = DateTime(2026, 6);
    final juneToday = DateTime(2026, 6, 20);

    testWidgets('shows month and year in header', (tester) async {
      await tester.pumpWidget(
        _wrap(
          DayStatusCalendar(
            statusByDate: const {},
            month: june2026,
            today: juneToday,
            onPrevMonth: () {},
            onNextMonth: () {},
          ),
        ),
      );
      expect(find.text('June 2026'), findsOneWidget);
    });

    testWidgets('shows day-of-week headers', (tester) async {
      await tester.pumpWidget(
        _wrap(
          DayStatusCalendar(
            statusByDate: const {},
            month: june2026,
            today: juneToday,
            onPrevMonth: () {},
            onNextMonth: () {},
          ),
        ),
      );
      expect(find.text('Mo'), findsOneWidget);
      expect(find.text('Su'), findsOneWidget);
    });

    testWidgets('calls onPrevMonth when left arrow tapped', (tester) async {
      var called = false;
      await tester.pumpWidget(
        _wrap(
          DayStatusCalendar(
            statusByDate: const {},
            month: june2026,
            today: juneToday,
            onPrevMonth: () => called = true,
            onNextMonth: () {},
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.chevron_left));
      expect(called, isTrue);
    });

    testWidgets('calls onNextMonth when right arrow tapped', (tester) async {
      var called = false;
      await tester.pumpWidget(
        _wrap(
          DayStatusCalendar(
            statusByDate: const {},
            month: june2026,
            today: juneToday,
            onPrevMonth: () {},
            onNextMonth: () => called = true,
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.chevron_right));
      expect(called, isTrue);
    });

    testWidgets('colors a green day', (tester) async {
      await tester.pumpWidget(
        _wrap(
          DayStatusCalendar(
            statusByDate: const {'2026-06-15': DayStatus.green},
            month: june2026,
            today: juneToday,
            onPrevMonth: () {},
            onNextMonth: () {},
          ),
        ),
      );
      expect(_colorOfDay(tester, '15'), Colors.green.shade700);
    });

    testWidgets('colors a yellow day', (tester) async {
      await tester.pumpWidget(
        _wrap(
          DayStatusCalendar(
            statusByDate: const {'2026-06-15': DayStatus.yellow},
            month: june2026,
            today: juneToday,
            onPrevMonth: () {},
            onNextMonth: () {},
          ),
        ),
      );
      expect(_colorOfDay(tester, '15'), Colors.amber.shade700);
    });

    testWidgets('colors a red day', (tester) async {
      await tester.pumpWidget(
        _wrap(
          DayStatusCalendar(
            statusByDate: const {'2026-06-15': DayStatus.red},
            month: june2026,
            today: juneToday,
            onPrevMonth: () {},
            onNextMonth: () {},
          ),
        ),
      );
      expect(_colorOfDay(tester, '15'), Colors.red.shade400);
    });

    testWidgets(
      'a past day absent from statusByDate renders black (not logged)',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            DayStatusCalendar(
              statusByDate: const {},
              month: june2026,
              today: juneToday,
              onPrevMonth: () {},
              onNextMonth: () {},
            ),
          ),
        );
        expect(_colorOfDay(tester, '15'), Colors.black);
      },
    );

    testWidgets(
      'a future day renders neutrally, never as a false not-logged cell',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            DayStatusCalendar(
              statusByDate: const {},
              month: june2026,
              today: DateTime(2026, 6, 10),
              onPrevMonth: () {},
              onNextMonth: () {},
            ),
          ),
        );
        // Day 25 is after the reference "today" of June 10.
        expect(_colorOfDay(tester, '25'), Colors.grey.shade800);
      },
    );

    testWidgets("today itself is classified, not treated as future", (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          DayStatusCalendar(
            statusByDate: const {'2026-06-20': DayStatus.red},
            month: june2026,
            today: juneToday,
            onPrevMonth: () {},
            onNextMonth: () {},
          ),
        ),
      );
      expect(_colorOfDay(tester, '20'), Colors.red.shade400);
    });

    testWidgets('renders a month starting on Sunday correctly', (
      tester,
    ) async {
      final sep2026 = DateTime(2026, 9);
      await tester.pumpWidget(
        _wrap(
          DayStatusCalendar(
            statusByDate: const {},
            month: sep2026,
            today: DateTime(2026, 9, 1),
            onPrevMonth: () {},
            onNextMonth: () {},
          ),
        ),
      );
      expect(find.text('September 2026'), findsOneWidget);
    });

    testWidgets('tapping a day calls onDaySelected with that date', (
      tester,
    ) async {
      DateTime? selected;
      await tester.pumpWidget(
        _wrap(
          DayStatusCalendar(
            statusByDate: const {'2026-06-15': DayStatus.green},
            month: june2026,
            today: juneToday,
            onPrevMonth: () {},
            onNextMonth: () {},
            onDaySelected: (day) => selected = day,
          ),
        ),
      );
      await tester.tap(find.text('15'));
      expect(selected, DateTime(2026, 6, 15));
    });

    testWidgets('no onDaySelected means day cells are not tappable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          DayStatusCalendar(
            statusByDate: const {},
            month: june2026,
            today: juneToday,
            onPrevMonth: () {},
            onNextMonth: () {},
          ),
        ),
      );
      // No GestureDetector wraps the day cells when onDaySelected is null;
      // tapping must not throw.
      await tester.tap(find.text('15'));
    });
  });
}
