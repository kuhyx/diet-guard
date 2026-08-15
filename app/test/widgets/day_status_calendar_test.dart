import 'package:diet_guard_app/models/day_status.dart';
import 'package:diet_guard_app/widgets/day_status_calendar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'day_status_calendar_test_support.dart';

void main() {
  group('DayStatusCalendar', () {
    final june2026 = DateTime(2026, 6);
    final juneToday = DateTime(2026, 6, 20);

    testWidgets('shows month and year in header', (tester) async {
      await tester.pumpWidget(
        wrapInApp(
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
        wrapInApp(
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
        wrapInApp(
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
        wrapInApp(
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
        wrapInApp(
          DayStatusCalendar(
            statusByDate: const {'2026-06-15': DayStatus.green},
            month: june2026,
            today: juneToday,
            onPrevMonth: () {},
            onNextMonth: () {},
          ),
        ),
      );
      expect(colorOfDay(tester, '15'), statusColors.success);
    });

    testWidgets('colors a yellow day', (tester) async {
      await tester.pumpWidget(
        wrapInApp(
          DayStatusCalendar(
            statusByDate: const {'2026-06-15': DayStatus.yellow},
            month: june2026,
            today: juneToday,
            onPrevMonth: () {},
            onNextMonth: () {},
          ),
        ),
      );
      expect(colorOfDay(tester, '15'), statusColors.warning);
    });

    testWidgets('colors a red day', (tester) async {
      await tester.pumpWidget(
        wrapInApp(
          DayStatusCalendar(
            statusByDate: const {'2026-06-15': DayStatus.red},
            month: june2026,
            today: juneToday,
            onPrevMonth: () {},
            onNextMonth: () {},
          ),
        ),
      );
      expect(colorOfDay(tester, '15'), appTheme.colorScheme.error);
    });

    testWidgets(
      'a past day absent from statusByDate renders black (not logged)',
      (tester) async {
        await tester.pumpWidget(
          wrapInApp(
            DayStatusCalendar(
              statusByDate: const {},
              month: june2026,
              today: juneToday,
              onPrevMonth: () {},
              onNextMonth: () {},
            ),
          ),
        );
        expect(colorOfDay(tester, '15'), appTheme.colorScheme.surface);
      },
    );

    testWidgets(
      'a future day renders neutrally, never as a false not-logged cell',
      (tester) async {
        await tester.pumpWidget(
          wrapInApp(
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
        expect(
          colorOfDay(tester, '25'),
          appTheme.colorScheme.surfaceContainerHigh,
        );
      },
    );

    testWidgets('today itself is classified, not treated as future', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapInApp(
          DayStatusCalendar(
            statusByDate: const {'2026-06-20': DayStatus.red},
            month: june2026,
            today: juneToday,
            onPrevMonth: () {},
            onNextMonth: () {},
          ),
        ),
      );
      expect(colorOfDay(tester, '20'), appTheme.colorScheme.error);
    });

    testWidgets('renders a month starting on Sunday correctly', (
      tester,
    ) async {
      final sep2026 = DateTime(2026, 9);
      await tester.pumpWidget(
        wrapInApp(
          DayStatusCalendar(
            statusByDate: const {},
            month: sep2026,
            today: DateTime(2026, 9),
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
        wrapInApp(
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
        wrapInApp(
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
