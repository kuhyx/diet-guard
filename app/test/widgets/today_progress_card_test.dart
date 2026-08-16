import 'package:diet_guard_app/widgets/today_progress_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TodayProgress _progress({
  double consumedKcal = 1450,
  int budgetKcal = 2200,
  double proteinG = 90,
  double carbsG = 120,
  double fatG = 40,
  int adherenceStreak = 3,
}) => TodayProgress(
  consumedKcal: consumedKcal,
  budgetKcal: budgetKcal,
  proteinG: proteinG,
  carbsG: carbsG,
  fatG: fatG,
  adherenceStreak: adherenceStreak,
);

Future<void> _pump(WidgetTester tester, TodayProgress progress) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TodayProgressCard(progress: progress)),
      ),
    );

void main() {
  group('TodayProgress', () {
    test('remaining is budget minus consumed', () {
      expect(_progress().remainingKcal, 750);
      expect(_progress().isOverBudget, isFalse);
    });

    test('remaining goes negative once past the budget', () {
      final over = _progress(consumedKcal: 2500);
      expect(over.remainingKcal, -300);
      expect(over.isOverBudget, isTrue);
    });

    test('exactly on the budget is not over', () {
      final exact = _progress(consumedKcal: 2200);
      expect(exact.remainingKcal, 0);
      expect(exact.isOverBudget, isFalse);
    });
  });

  group('TodayProgressCard', () {
    testWidgets('shows the kcal position and macros, but not the meal', (
      tester,
    ) async {
      await _pump(tester, _progress());

      // The `Logged "<meal>".` line was removed 2026-08-16 -- it restated
      // what the user had just typed. Pinned so it does not creep back.
      expect(find.textContaining('Logged'), findsNothing);
      expect(find.text('1450 / 2200'), findsOneWidget);
      expect(find.text('750 left'), findsOneWidget);
      expect(find.text('P 90g  ·  C 120g  ·  F 40g'), findsOneWidget);
    });

    testWidgets('reports the overshoot in the error color when over', (
      tester,
    ) async {
      await _pump(tester, _progress(consumedKcal: 2500));

      expect(find.text('300 over'), findsOneWidget);
      final total = tester.widget<Text>(find.text('2500 / 2200'));
      final context = tester.element(find.text('2500 / 2200'));
      expect(total.style?.color, Theme.of(context).colorScheme.error);
    });

    testWidgets('pluralises the adherence streak', (tester) async {
      await _pump(tester, _progress(adherenceStreak: 1));
      expect(find.text('Adherence streak: 1 day'), findsOneWidget);

      await _pump(tester, _progress(adherenceStreak: 12));
      expect(find.text('Adherence streak: 12 days'), findsOneWidget);
    });

    testWidgets('rounds fractional kcal and macros for display', (
      tester,
    ) async {
      await _pump(
        tester,
        _progress(consumedKcal: 1450.6, proteinG: 90.4, carbsG: 0, fatG: 0),
      );

      expect(find.text('1451 / 2200'), findsOneWidget);
      expect(find.text('P 90g  ·  C 0g  ·  F 0g'), findsOneWidget);
    });
  });
}
