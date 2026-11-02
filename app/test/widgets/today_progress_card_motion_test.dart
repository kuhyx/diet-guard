import 'package:diet_guard_app/widgets/today_progress_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TodayProgress _progress({
  double consumedKcal = 1450,
  double? previousKcal,
  int adherenceStreak = 3,
  int? previousAdherenceStreak,
  int? loggedSlotMinute,
  double? loggedKcal,
}) => TodayProgress(
  consumedKcal: consumedKcal,
  budgetKcal: 2200,
  proteinG: 90,
  carbsG: 120,
  fatG: 40,
  adherenceStreak: adherenceStreak,
  previousKcal: previousKcal,
  previousAdherenceStreak: previousAdherenceStreak,
  loggedSlotMinute: loggedSlotMinute,
  loggedKcal: loggedKcal,
);

Future<void> _pump(
  WidgetTester tester,
  TodayProgress progress, {
  bool reduced = false,
}) => tester.pumpWidget(
  MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: MaterialApp(
      home: Scaffold(body: TodayProgressCard(progress: progress)),
    ),
  ),
);

double _entranceOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .descendant(
            of: find.byType(TodayProgressCard),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

void main() {
  group('confirmation line', () {
    testWidgets('prints whole kcal without decimals', (tester) async {
      await _pump(tester, _progress(loggedSlotMinute: 720, loggedKcal: 450));
      expect(find.text('✓ 12:00 · 450 kcal'), findsOneWidget);
      expect(find.textContaining('Logged'), findsNothing);
    });

    testWidgets('keeps fractional kcal exact', (tester) async {
      await _pump(tester, _progress(loggedSlotMinute: 495, loggedKcal: 450.5));
      expect(find.text('✓ 08:15 · 450.5 kcal'), findsOneWidget);
    });

    testWidgets('is absent when the logged fields are null', (tester) async {
      await _pump(tester, _progress());
      expect(find.textContaining('✓'), findsNothing);
      await _pump(tester, _progress(loggedSlotMinute: 720));
      expect(find.textContaining('✓'), findsNothing);
      await _pump(tester, _progress(loggedKcal: 450));
      expect(find.textContaining('✓'), findsNothing);
    });
  });

  group('count-up', () {
    testWidgets('runs from previousKcal to consumedKcal', (tester) async {
      await _pump(tester, _progress(previousKcal: 1000));
      expect(find.text('1000 / 2200'), findsOneWidget);
      expect(find.text('1200 left'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 160));
      final mid = tester.widget<Text>(find.textContaining(' / 2200')).data!;
      final value = int.parse(mid.split(' / ').first);
      expect(value, greaterThan(1000));
      expect(value, lessThan(1450));

      await tester.pumpAndSettle();
      expect(find.text('1450 / 2200'), findsOneWidget);
      expect(find.text('750 left'), findsOneWidget);
    });

    testWidgets('is static without previousKcal', (tester) async {
      await _pump(tester, _progress());
      expect(find.text('1450 / 2200'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 160));
      expect(find.text('1450 / 2200'), findsOneWidget);
    });

    testWidgets('over-budget label and colour follow the animation', (
      tester,
    ) async {
      await _pump(tester, _progress(consumedKcal: 2500, previousKcal: 2000));
      expect(find.text('200 left'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('2500 / 2200'), findsOneWidget);
      expect(find.text('300 over'), findsOneWidget);
    });

    testWidgets('streak counts up when it changed', (tester) async {
      await _pump(tester, _progress(previousAdherenceStreak: 2));
      expect(find.text('Adherence streak: 2 days'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Adherence streak: 3 days'), findsOneWidget);
    });

    testWidgets('streak is static when unchanged', (tester) async {
      await _pump(tester, _progress(previousAdherenceStreak: 3));
      expect(find.text('Adherence streak: 3 days'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 160));
      expect(find.text('Adherence streak: 3 days'), findsOneWidget);
    });
  });

  group('reduced motion', () {
    testWidgets('first frame shows the final values at full opacity', (
      tester,
    ) async {
      await _pump(
        tester,
        _progress(previousKcal: 1000, previousAdherenceStreak: 2),
        reduced: true,
      );
      expect(find.text('1450 / 2200'), findsOneWidget);
      expect(find.text('750 left'), findsOneWidget);
      expect(find.text('Adherence streak: 3 days'), findsOneWidget);
      expect(_entranceOpacity(tester), 1);
    });
  });

  group('entrance', () {
    testWidgets('starts transparent and ends opaque', (tester) async {
      await _pump(tester, _progress());
      expect(_entranceOpacity(tester), lessThan(1));
      await tester.pumpAndSettle();
      expect(_entranceOpacity(tester), 1);
    });

    testWidgets('replays for a new TodayProgress instance', (tester) async {
      await _pump(tester, _progress());
      await tester.pumpAndSettle();
      await _pump(tester, _progress());
      expect(_entranceOpacity(tester), lessThan(1));
      await tester.pumpAndSettle();
    });
  });
}
