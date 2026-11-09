import 'package:diet_guard_app/models/day_status.dart';
import 'package:diet_guard_app/widgets/streak_summary_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../label_finders.dart';

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
      expect(find.text('3'), findsWidgets);
      expect(byIconLabel('Logging streak'), findsOneWidget);
      expect(byIconLabel('Adherence streak'), findsOneWidget);
      expect(find.text('10/14'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
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
      expect(find.text('1'), findsWidgets);
      expect(byIconLabel('Logging streak'), findsOneWidget);
      expect(byIconLabel('Adherence streak'), findsOneWidget);
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
      expect(find.text('0'), findsWidgets);
      expect(byIconLabel('Logging streak'), findsOneWidget);
      expect(byIconLabel('Adherence streak'), findsOneWidget);
    });
  });
}
