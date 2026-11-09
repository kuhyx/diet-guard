import 'package:diet_guard_app/models/period_average.dart';
import 'package:diet_guard_app/widgets/average_summary_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../label_finders.dart';

PeriodAverage period({double? avgKcal, AverageBand? band}) => PeriodAverage(
  start: '2026-01-05',
  end: '2026-01-11',
  loggedDays: 7,
  elapsedDays: 7,
  avgKcal: avgKcal,
  avgBudget: 2000,
  band: band,
);

Future<void> pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  testWidgets('renders both averages and their bands', (tester) async {
    await pump(
      tester,
      AverageSummaryRow(
        week: period(avgKcal: 2100, band: AverageBand.slightlyOver),
        month: period(avgKcal: 1900, band: AverageBand.under),
      ),
    );
    expect(find.text('2100'), findsOneWidget);
    expect(find.text('1900'), findsOneWidget);
    expect(byIconLabel('slightly over'), findsOneWidget);
    expect(byIconLabel('under'), findsOneWidget);
  });

  testWidgets('rounds the average to whole kcal', (tester) async {
    await pump(
      tester,
      AverageSummaryRow(
        week: period(avgKcal: 2100.6, band: AverageBand.slightlyOver),
        month: period(avgKcal: 1900, band: AverageBand.under),
      ),
    );
    expect(find.text('2101'), findsOneWidget);
  });

  testWidgets('an empty period shows the no-data glyph, never 0', (
    tester,
  ) async {
    await pump(tester, AverageSummaryRow(week: period(), month: period()));
    expect(find.text('0'), findsNothing);
    expect(byIconLabel('no data'), findsNWidgets(2));
  });

  testWidgets('the placeholder empty period renders safely', (tester) async {
    await pump(
      tester,
      const AverageSummaryRow(
        week: PeriodAverage.empty,
        month: PeriodAverage.empty,
      ),
    );
    expect(byIconLabel('no data'), findsNWidgets(2));
  });
}
