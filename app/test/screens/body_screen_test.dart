import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/screens/body_screen.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/ui/cues.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../label_finders.dart';
import 'body_screen_support.dart';

void main() {
  late MemoryDocStore store;

  setUp(() async {
    store = MemoryDocStore();
    await setUpBodyServices(store);
  });
  tearDown(tearDownBodyServices);

  testWidgets('with nothing set the profile is first and asks for data', (
    tester,
  ) async {
    await pumpBody(tester);
    expect(tileTitles(tester).first, 'Profile');
    // Unknown age: the profile tile carries no number and no cake.
    expect(
      find.descendant(of: tile('Profile'), matching: find.byIcon(Icons.cake)),
      findsNothing,
    );
    await openTile(tester, 'Daily calorie target');
    // Both inputs missing: one warning glyph each (profile, weight).
    expect(cueOfKind(CueKind.warn), findsNWidgets(2));
    expect(
      cueLabelled(bodyMissingNote(BodyService.instance)),
      findsNWidgets(2),
    );
    await closeSheet(tester);
    await openTile(tester, 'Activity');
    expect(
      cueLabelled('No activity data yet -- published by the PC.'),
      findsOneWidget,
    );
    await closeSheet(tester);
    await openTile(tester, 'Weight');
    expect(byIconLabel('Need two readings for a graph.'), findsOneWidget);
    await closeSheet(tester);
    await openTile(tester, 'Body fat');
    expect(byIconLabel('Need two readings for a graph.'), findsOneWidget);
  });

  testWidgets('a weight without a profile asks for the profile', (
    tester,
  ) async {
    await BodyService.instance.setWeight('2026-09-20', 80);
    await pumpBody(tester);
    await openTile(tester, 'Daily calorie target');
    expect(
      cueLabelled(
        'Set your profile (birth date, height, sex) to see the numbers.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a profile without a weight asks for the weight', (tester) async {
    await BodyService.instance.setProfile(
      birth: '1990-01-01',
      heightCm: 180,
      sex: 'f',
    );
    await pumpBody(tester);
    await openTile(tester, 'Daily calorie target');
    expect(
      cueLabelled('Enter your weight to see the numbers.'),
      findsOneWidget,
    );
  });

  testWidgets('a full profile: goal first, profile then body fat last', (
    tester,
  ) async {
    await seedPerson(store);
    await pumpBody(tester);
    final titles = tileTitles(tester);
    expect(titles.first, 'Daily calorie target');
    expect(titles.indexOf('Weight'), 1);
    expect(
      titles.indexOf('Profile'),
      greaterThan(titles.indexOf('Week planner (info only)')),
    );
    expect(titles.last, 'Body fat');
    // Headline numbers on the tiles themselves.
    expect(
      find.descendant(
        of: tile('Daily calorie target'),
        matching: find.text('2209'),
      ),
      findsOneWidget,
    );
    expect(find.text('80.0 kg'), findsOneWidget);
    expect(find.text('24.7'), findsOneWidget);
    expect(
      find.descendant(of: tile('Profile'), matching: find.text('30')),
      findsOneWidget,
    );

    // 80 kg, 180 cm, 30 y, male, lose 0.5 kg/week on Moderate:
    // 1780 x 1.55 - 550 = 2209.
    await openTile(tester, 'Daily calorie target');
    expect(inSheet(find.text('2209')), findsOneWidget);
    expect(inSheet(find.text('2759')), findsOneWidget);
    expect(inSheet(find.text('Mifflin-St Jeor')), findsOneWidget);
    await closeSheet(tester);
    await openTile(tester, 'BMI');
    expect(inSheet(find.text('24.7')), findsOneWidget);
    expect(find.text('59.9-80.7 kg'), findsOneWidget);
    expect(byIconLabel('normal'), findsOneWidget);
    await closeSheet(tester);
    await openTile(tester, 'Ideal weight');
    expect(byIconLabel('Average of all'), findsOneWidget);
    expect(find.textContaining('Broca'), findsNothing);
    await closeSheet(tester);
    await openTile(tester, 'Resting metabolism (BMR)');
    expect(inSheet(find.text('1780')), findsOneWidget);
    expect(byIconLabel('n/a -- log a body-fat %'), findsNWidgets(2));
    await closeSheet(tester);
    // 5000 steps over baseline x 0.747 m x 0.5 x 80 kg = 149.4 kcal, and
    // all the data is from yesterday, so the window is that one day.
    await openTile(tester, 'Activity');
    expect(find.text('9000  ${yesterdayKey()}'), findsOneWidget);
    expect(inSheet(find.text('149')), findsOneWidget);
    expect(
      byIconLabel('Mean daily exercise, last 1 full days:'),
      findsOneWidget,
    );
    expect(find.textContaining('Evening run'), findsOneWidget);
    expect(find.textContaining('StrongLifts A'), findsOneWidget);
    expect(byIconLabel('Connect Health Connect steps'), findsNothing);
  });

  testWidgets('a body fat switches the target to Katch-McArdle', (
    tester,
  ) async {
    await seedPerson(store);
    await pumpBody(tester);
    await openTile(tester, 'Body fat');
    final field = fieldByLabel('Body fat (%)');
    await tester.enterText(field, '99');
    await tester.tap(byIconLabel('Save'));
    await tester.pumpAndSettle();
    expect(cueLabelled('Body fat must be 3-70 %.'), findsOneWidget);
    expect(cueOfKind(CueKind.error), findsOneWidget);

    await tester.enterText(field, '18,5');
    await tester.tap(byIconLabel('Save'));
    await tester.pumpAndSettle();
    expect(BodyService.instance.latestBodyFat?.$2, 18.5);
    await closeSheet(tester);
    expect(find.text('18.5 %'), findsOneWidget);
    await openTile(tester, 'Daily calorie target');
    expect(inSheet(find.text('Katch-McArdle')), findsOneWidget);
    expect(inSheet(find.text('2206')), findsOneWidget);
    await closeSheet(tester);
    await openTile(tester, 'Resting metabolism (BMR)');
    expect(inSheet(find.text('1778')), findsOneWidget);
  });

  testWidgets('saving and deleting a weight updates the numbers', (
    tester,
  ) async {
    await seedPerson(store);
    await pumpBody(tester);
    await openTile(tester, 'Weight');
    final field = fieldByLabel('Weight (kg)');
    await tester.enterText(field, '5');
    await tester.tap(byIconLabel('Save'));
    await tester.pumpAndSettle();
    expect(cueLabelled('Weight must be 20-400 kg.'), findsOneWidget);

    await tester.enterText(field, '90,5');
    await tester.tap(byIconLabel('Save'));
    await tester.pumpAndSettle();
    final today = localDateKey(DateTime.now());
    expect(BodyService.instance.latestWeight, (today, 90.5));
    await closeSheet(tester);
    expect(find.text('27.9'), findsOneWidget); // 90.5 / 1.8^2 on the BMI tile

    await openTile(tester, 'Weight');
    await tester.tap(byIconLabel('Delete this day').first);
    await tester.pumpAndSettle();
    expect(BodyService.instance.latestWeight?.$1, yesterdayKey());

    // The undo arrow brings the deleted day back, value and all.
    await tester.tap(byIconLabel('Undo'));
    await tester.pumpAndSettle();
    expect(BodyService.instance.latestWeight, (today, 90.5));
  });

  testWidgets('the profile form validates height and saves', (tester) async {
    await pumpBody(tester);
    await openTile(tester, 'Profile');
    final field = fieldByLabel('Height (cm)');
    await tester.enterText(field, '9');
    await tester.tap(byIconLabel('Save profile'));
    await tester.pumpAndSettle();
    expect(cueLabelled('Height must be 50-260 cm.'), findsOneWidget);

    await tester.enterText(field, '172.5');
    await tester.tap(byIconLabel('Female'));
    await tester.tap(byIconLabel('Save profile'));
    await tester.pumpAndSettle();
    expect(BodyService.instance.heightCm, 172.5);
    expect(BodyService.instance.sex, 'f');
    expect(cueLabelled('Saved.'), findsOneWidget);
  });

  test('kcalByDay of an empty log is empty', () {
    expect(kcalByDay(const {}), isEmpty);
  });
}
