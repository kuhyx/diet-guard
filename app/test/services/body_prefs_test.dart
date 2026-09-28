import 'package:diet_guard_app/models/body_document.dart';
import 'package:diet_guard_app/services/body_energy.dart';
import 'package:diet_guard_app/services/body_prefs.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'body_test_support.dart';

void main() {
  late BodyService body;

  setUp(() async => body = await BodyService.initForTesting(MemoryDocStore()));
  tearDown(BodyService.resetForTesting);

  test('unset reads as the default goal', () {
    final goal = savedGoal(body);
    expect(goalToJson(goal), goalToJson(defaultGoal));
  });

  test('each part falls back to the default on its own', () {
    final goal = goalFromJson({
      'dir': 'gain',
      'amt': -1,
      'wu': 'furlong',
      'tu': 'month',
      'act': 'measured:ACSM',
    });
    expect(goal.direction, 'gain');
    expect(goal.amount, defaultGoal.amount);
    expect(goal.weightUnit, 'kg');
    expect(goal.timeUnit, 'month');
    expect(goal.activity, 'measured:ACSM');
    expect(goalFromJson({'amt': true, 'act': 3}).activity, 'moderate');
    expect(goalToJson(goalFromJson('nope')), goalToJson(defaultGoal));
  });

  test('saving syncs one field and never re-stamps the profile', () async {
    await body.setProfile(
      birth: '1990-01-01',
      now: DateTime.parse('2026-09-01T10:00:00'),
    );
    const goal = Goal('gain', 2, 'lb', 'month', 'extra');
    await setGoal(body, goal);
    expect(body.profileValue(goalField), goalToJson(goal));
    expect(goalToJson(savedGoal(body)), goalToJson(goal));
    expect(body.document.profile[profileBirth]!.t, startsWith('2026-09-01T10'));
  });

  test('goal arithmetic: units, maintain and measured without data', () {
    expect(const Goal('maintain', 9, 'kg', 'day', 'light').kgPerDay(), 0);
    expect(
      const Goal('gain', 7, 'kg', 'week', 'light').kgPerDay(),
      closeTo(-1, 1e-12),
    );
    final missing = goalTarget(
      const Goal('lose', 1, 'kg', 'week', 'measured:MET'),
      1800,
      'Mifflin-St Jeor',
      null,
    );
    expect(missing.kcal, isNull);
    expect(missing.tdee, isNull);
    expect(missing.belowFloor, isFalse);
    expect(
      goalTarget(defaultGoal.copyWith(activity: '?'), 1800, 'x', null).kcal,
      isNull,
    );
    expect(activityLabel('measured:Per-km'), 'Measured (Per-km)');
    expect(activityLabel('very'), 'Very active');
    expect(activityLabel('?'), '?');
    expect(formatG(1 / 3), '0.333333');
    expect(formatG(0.25), '0.25');
    expect(formatG(1e20), '1.00000e+20');
  });
}
