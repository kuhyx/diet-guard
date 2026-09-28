import 'package:diet_guard_app/services/activity_kcal.dart';
import 'package:diet_guard_app/services/body_calc.dart';
import 'package:diet_guard_app/services/week_plan.dart';
import 'package:diet_guard_app/widgets/body/activity_card.dart';
import 'package:diet_guard_app/widgets/body/body_stats_cards.dart';
import 'package:diet_guard_app/widgets/body/week_plan_card.dart';
import 'package:diet_guard_app/widgets/body/weight_chart.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';


Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

const _short = Biometrics(
  weightKg: 50,
  heightCm: 150,
  ageYears: 17,
  isMale: false,
);

void main() {
  group('helpers', () {
    test('halfUp rounds half away from banker', () {
      expect(halfUp(2.5), 3);
      expect(halfUp(0.125, 2), 0.13);
    });

    test('ageOn counts completed years', () {
      final birth = DateTime(1995, 3, 1);
      expect(ageOn(birth, DateTime(2026, 2, 28)), 30);
      expect(ageOn(birth, DateTime(2026, 3, 1)), 31);
      expect(ageOn(birth, DateTime(2026, 3, 2)), 31);
      expect(ageOn(DateTime(1995, 3, 15), DateTime(2026, 3, 2)), 30);
    });

    test('weekStart is the local Monday', () {
      expect(weekStart(DateTime(2026, 10, 4, 18)), DateTime(2026, 9, 28));
    });

    test('an unknown session kind uses the generic MET', () {
      const s = Session(
        day: '2026-09-27',
        kind: 'yoga',
        minutes: 60,
        km: null,
        label: 'yoga',
        source: '',
      );
      expect(metFor(s), 4);
    });

    test('seriesInRange keeps the last N days', () {
      final series = [('2026-01-01', 80.0), ('2026-09-20', 79.0)];
      final today = DateTime(2026, 9, 27);
      expect(seriesInRange(series, 30, today), [('2026-09-20', 79.0)]);
      expect(seriesInRange(series, null, today), series);
    });
  });

  testWidgets('a short teenager sees n/a formulas and the age note', (
    tester,
  ) async {
    await _pump(
      tester,
      const Column(
        children: [BmiCard(bio: _short), IdealWeightCard(bio: _short)],
      ),
    );
    expect(find.text('n/a'), findsNWidgets(4));
    expect(find.textContaining('undefined below 152.4 cm'), findsOneWidget);
    expect(find.text('adult categories do not apply under 20'), findsOneWidget);
  });

  testWidgets('activity card states', (tester) async {
    await _pump(
      tester,
      const ActivityCard(sessions: [], weightKg: null, exercise: null),
    );
    expect(find.textContaining('Enter your weight'), findsOneWidget);
    await _pump(
      tester,
      const ActivityCard(
        sessions: [],
        weightKg: 80,
        exercise: {'MET': 0, 'ACSM': 0, 'Per-km': 0},
      ),
    );
    expect(find.textContaining('No workouts in the last 28 days'), findsOne);
    expect(find.text('0 kcal/day'), findsNWidgets(3));
    var tapped = false;
    await _pump(
      tester,
      ActivityCard(
        sessions: null,
        weightKg: null,
        exercise: null,
        steps: const {'2026-09-26': 3000, '2026-09-27': 12000},
        stepsKcal: 20,
        onConnectSteps: () => tapped = true,
      ),
    );
    expect(find.textContaining('No activity data yet'), findsNothing);
    expect(
      find.textContaining('12000 on 2026-09-27; above 4000/day they add 20'),
      findsOneWidget,
    );
    await tester.tap(find.text('Connect Health Connect steps'));
    expect(tapped, isTrue);
  });

  testWidgets('the chart plots two weigh-ins and switches range', (
    tester,
  ) async {
    await _pump(
      tester,
      WeightChart(
        series: const [('2026-06-01', 82.0), ('2026-09-20', 79.5)],
        today: DateTime(2026, 9, 27),
      ),
    );
    expect(find.text('Need two readings for a graph.'), findsOneWidget);
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.byType(LineChart), findsOneWidget);
  });

  testWidgets('the week planner fills logged days and honours typing', (
    tester,
  ) async {
    await _pump(
      tester,
      WeekPlanCard(
        defaultTarget: 2000,
        logged: const {'2026-09-28': 2500},
        today: DateTime(2026, 9, 30),
      ),
    );
    // Mon logged, Tue unlogged: (14000 - 2500) / 6 = 1917.
    expect(find.textContaining('2500 kcal  (logged)'), findsOneWidget);
    expect(find.textContaining('(not logged -- type it)'), findsOneWidget);
    expect(find.textContaining('Eat 1917 kcal'), findsOneWidget);

    final dayFields = find.widgetWithText(TextField, 'ate…');
    await tester.enterText(dayFields.at(1), '1800');
    await tester.pumpAndSettle();
    expect(find.textContaining('1800 kcal  (typed)'), findsOneWidget);
    expect(find.textContaining('Eat 1940 kcal'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Weekly average target (kcal/day)'),
      '900',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('below the 1200 kcal floor'), findsOneWidget);

    for (var i = 0; i < 7; i++) {
      await tester.enterText(dayFields.at(i), '2000');
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('Every day is known'), findsOneWidget);
  });
}
