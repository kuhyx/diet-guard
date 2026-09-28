import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/screens/body_screen.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/widgets/body/profile_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'body_screen_support.dart';

void main() {
  late MemoryDocStore store;

  setUp(() async {
    store = MemoryDocStore();
    await setUpBodyServices(store);
  });
  tearDown(tearDownBodyServices);

  testWidgets('with nothing set the profile is on top and asks for data', (
    tester,
  ) async {
    await pumpBody(tester);
    expect(find.textContaining('Set your profile and enter'), findsOneWidget);
    expect(find.textContaining('No activity data yet'), findsOneWidget);
    expect(find.text('Need two readings for a graph.'), findsNWidgets(2));
    expect(find.textContaining('Age unknown'), findsOneWidget);
    expect(
      topOf(tester, find.byType(ProfileCard)),
      lessThan(topOf(tester, find.text('Daily calorie target'))),
    );
  });

  testWidgets('a weight without a profile asks for the profile', (
    tester,
  ) async {
    await BodyService.instance.setWeight('2026-09-20', 80);
    await pumpBody(tester);
    expect(find.textContaining('Set your profile (birth'), findsOneWidget);
  });

  testWidgets('a profile without a weight asks for the weight', (tester) async {
    await BodyService.instance.setProfile(
      birth: '1990-01-01',
      heightCm: 180,
      sex: 'f',
    );
    await pumpBody(tester);
    expect(find.text('Enter your weight to see the numbers.'), findsOneWidget);
  });

  testWidgets('a full profile: goal first, profile then body fat last', (
    tester,
  ) async {
    await seedPerson(store);
    await pumpBody(tester);
    final goalTop = topOf(tester, find.text('Daily calorie target'));
    expect(goalTop, lessThan(topOf(tester, find.text('Weight'))));
    final profileTop = topOf(tester, find.byType(ProfileCard));
    expect(
      profileTop,
      greaterThan(topOf(tester, find.text('Week planner (info only)'))),
    );
    expect(topOf(tester, find.text('Body fat')), greaterThan(profileTop));
    // 80 kg, 180 cm, 30 y, male, lose 0.5 kg/week on Moderate:
    // 1780 x 1.55 - 550 = 2209.
    expect(find.text('2209'), findsOneWidget);
    expect(
      find.textContaining('Maintenance 2759 kcal (Mifflin-St Jeor'),
      findsOneWidget,
    );
    expect(find.text('24.7'), findsOneWidget);
    expect(find.text('59.9-80.7 kg'), findsOneWidget);
    expect(find.text('Average of all'), findsOneWidget);
    expect(find.textContaining('Broca = height'), findsOneWidget);
    expect(find.text('1780 kcal'), findsOneWidget);
    expect(find.text('n/a -- log a body-fat %'), findsNWidgets(2));
    // 5000 steps over baseline x 0.747 m x 0.5 x 80 kg = 149.4 kcal, and
    // all the data is from yesterday, so the window is that one day.
    expect(
      find.textContaining('Steps outside workouts: 9000 on ${yesterdayKey()}'),
      findsOneWidget,
    );
    expect(find.textContaining('add 149 kcal/day'), findsOneWidget);
    expect(find.text('Mean daily exercise, last 1 full days:'), findsOneWidget);
    expect(find.textContaining('Evening run'), findsOneWidget);
    expect(find.textContaining('StrongLifts A'), findsOneWidget);
    expect(find.textContaining('Age 30'), findsOneWidget);
    expect(find.text('Connect Health Connect steps'), findsNothing);
  });

  testWidgets('a body fat switches the target to Katch-McArdle', (
    tester,
  ) async {
    await seedPerson(store);
    await pumpBody(tester);
    final field = find.widgetWithText(TextField, 'Body fat (%)');
    await tester.enterText(field, '99');
    await tester.tap(find.text('Save').at(1));
    await tester.pumpAndSettle();
    expect(find.text('Body fat must be 3-70 %.'), findsOneWidget);

    await tester.enterText(field, '18,5');
    await tester.tap(find.text('Save').at(1));
    await tester.pumpAndSettle();
    expect(BodyService.instance.latestBodyFat?.$2, 18.5);
    expect(find.textContaining('(Katch-McArdle resting'), findsOneWidget);
    expect(find.text('1778 kcal'), findsOneWidget);
    expect(find.text('2206'), findsOneWidget);
  });

  testWidgets('saving and deleting a weight updates the numbers', (
    tester,
  ) async {
    await seedPerson(store);
    await pumpBody(tester);
    final field = find.widgetWithText(TextField, 'Weight (kg)');
    await tester.enterText(field, '5');
    await tester.tap(find.text('Save').first);
    await tester.pumpAndSettle();
    expect(find.text('Weight must be 20-400 kg.'), findsOneWidget);

    await tester.enterText(field, '90,5');
    await tester.tap(find.text('Save').first);
    await tester.pumpAndSettle();
    final today = localDateKey(DateTime.now());
    expect(BodyService.instance.latestWeight, (today, 90.5));
    expect(find.text('27.9'), findsOneWidget); // 90.5 / 1.8^2

    await tester.tap(find.byTooltip('Delete this day').first);
    await tester.pumpAndSettle();
    expect(BodyService.instance.latestWeight?.$1, yesterdayKey());
  });

  testWidgets('the profile form validates height and saves', (tester) async {
    await pumpBody(tester);
    final field = find.widgetWithText(TextField, 'Height (cm)');
    await tester.enterText(field, '9');
    await tester.tap(find.text('Save profile'));
    await tester.pumpAndSettle();
    expect(find.text('Height must be 50-260 cm.'), findsOneWidget);

    await tester.enterText(field, '172.5');
    await tester.tap(find.text('Female'));
    await tester.tap(find.text('Save profile'));
    await tester.pumpAndSettle();
    expect(BodyService.instance.heightCm, 172.5);
    expect(BodyService.instance.sex, 'f');
    expect(find.text('Saved.'), findsOneWidget);
  });

  test('kcalByDay of an empty log is empty', () {
    expect(kcalByDay(const {}), isEmpty);
  });
}
