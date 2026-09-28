import 'package:diet_guard_app/models/body_document.dart';
import 'package:diet_guard_app/services/body_energy.dart';
import 'package:diet_guard_app/services/body_prefs.dart';
import 'package:diet_guard_app/services/body_service.dart';
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

  testWidgets('each word of the goal is a picker, saved at once', (
    tester,
  ) async {
    await seedPerson(store);
    await pumpBody(tester);
    Future<void> choose(String word, String option) async {
      await tester.tap(find.text(word).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(option).last);
      await tester.pumpAndSettle();
    }

    await choose('lose', 'gain');
    await choose('kg', 'lb');
    await choose('week', 'month');
    await choose('Moderate', 'Measured (ACSM)');
    await tester.tap(find.text('0.5'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '1'));
    await tester.pumpAndSettle();
    expect(goalToJson(savedGoal(BodyService.instance)), {
      'dir': 'gain',
      'amt': 1.0,
      'wu': 'lb',
      'tu': 'month',
      'act': 'measured:ACSM',
    });
    expect(
      BodyService.instance.document.profile[profileBirth]!.t,
      '2026-09-01T10:00:00+02:00',
    );

    // A typed amount; junk is refused and the dialog stays open.
    final other = find.widgetWithText(TextField, 'Other amount');
    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    await tester.enterText(other, '');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('OK'), findsOneWidget);
    await tester.enterText(other, '2,5');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(savedGoal(BodyService.instance).amount, 2.5);

    // Cancel changes nothing; neither does dismissing a sheet.
    await tester.tap(find.text('2.5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('gain'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(savedGoal(BodyService.instance).amount, 2.5);

    await choose('gain', 'maintain');
    expect(find.text('lb'), findsNothing);
  });

  testWidgets('measured without data, and a goal below the floor', (
    tester,
  ) async {
    final body = BodyService.instance;
    await body.setProfile(birth: '1990-01-01', heightCm: 180, sex: 'm');
    await body.setWeight('2026-09-20', 80);
    await setGoal(body, const Goal('lose', 1, 'kg', 'week', 'measured:MET'));
    await pumpBody(tester);
    expect(find.textContaining('no workouts published yet'), findsOneWidget);
    await tester.tap(find.text('Measured (MET)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sedentary').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Other amount'), '3');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.textContaining('below the 1200 kcal floor'), findsOneWidget);
  });
}
