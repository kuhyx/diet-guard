import 'package:diet_guard_app/models/day_status.dart';
import 'package:diet_guard_app/widgets/streak_summary_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('StreakSummaryRow', () {
    testWidgets('renders plural streak counts', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const StreakSummaryRow(
            loggingStreak: 3,
            adherenceStreak: 2,
            tally: YtdTally(loggedDays: 10, elapsedDays: 14, adherentDays: 8),
          ),
        ),
      );
      expect(
        find.text(
          'Logging streak: 3 days  ·  Adherence streak: 2 days',
        ),
        findsOneWidget,
      );
      expect(
        find.text('This year: logged 10/14 days  ·  8 within budget'),
        findsOneWidget,
      );
    });

    testWidgets('renders singular streak counts', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const StreakSummaryRow(
            loggingStreak: 1,
            adherenceStreak: 1,
            tally: YtdTally(loggedDays: 1, elapsedDays: 1, adherentDays: 1),
          ),
        ),
      );
      expect(
        find.text('Logging streak: 1 day  ·  Adherence streak: 1 day'),
        findsOneWidget,
      );
    });

    testWidgets('renders zero streaks', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const StreakSummaryRow(
            loggingStreak: 0,
            adherenceStreak: 0,
            tally: YtdTally(loggedDays: 0, elapsedDays: 5, adherentDays: 0),
          ),
        ),
      );
      expect(
        find.text('Logging streak: 0 days  ·  Adherence streak: 0 days'),
        findsOneWidget,
      );
    });
  });
}
