/// The Dart half of the "Fill all with catering" parity gate.
///
/// `diet_guard/tests/test_kuchnia_parity.py` runs Python's `fill_plan` and
/// `log_dishes` over the *same* `expected.fill` cases of
/// `tests/fixtures/kuchnia_day.json`, whose expected lists are generated from
/// the Python implementation by `scripts/build_kuchnia_fixture.py`. A
/// divergence means the two devices fill different slots from one delivery.
///
/// Each case's `take` indexes the parsed dishes; the subset is re-spread over
/// `slots` (never a slice of the full spread). Split from
/// `kuchnia_parity_test.dart` to keep both under the 250-line cap.
library;

import 'dart:convert';
import 'dart:io';

import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/services/kuchnia_fill.dart';
import 'package:diet_guard_app/services/kuchnia_parse.dart';
import 'package:diet_guard_app/services/kuchnia_spread.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'services/body_test_support.dart';

/// The repo root, found by walking up to `app/` (as `kuchnia_parity_test`).
Directory get _repoRoot {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate app/ from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir.parent;
}

const _seedNutrition = Nutrition(
  kcal: 100,
  proteinG: 1,
  carbsG: 1,
  fatG: 1,
  grams: 100,
  source: 'manual',
);

List<List<Object?>> _pairs(Iterable<SlottedDish> items) => [
  for (final item in items) [item.dish.name, item.slot],
];

void main() {
  late Map<String, dynamic> fill;
  late List<KuchniaDish> dishes;

  setUpAll(() {
    final file = File('${_repoRoot.path}/tests/fixtures/kuchnia_day.json');
    final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    fill =
        (fixture['expected'] as Map<String, dynamic>)['fill']
            as Map<String, dynamic>;
    dishes = parseMenu(fixture['payload']);
  });

  setUp(() => LogStorageService.resetForTesting(store: MemoryDocStore()));
  tearDown(LogStorageService.resetForTesting);

  List<SlottedDish> spread(Map<String, dynamic> testCase) => assignSlots([
    for (final i in testCase['take'] as List) dishes[i as int],
  ], (fill['slots'] as List).cast<int>());

  Map<String, dynamic> cases(String group) =>
      fill[group] as Map<String, dynamic>;

  test('fillPlan keeps the same dishes as Python fill_plan', () {
    expect(cases('fill_plan'), isNotEmpty);
    for (final entry in cases('fill_plan').entries) {
      final testCase = entry.value as Map<String, dynamic>;
      final occupied = (testCase['occupied'] as List).cast<int>().toSet();
      expect(
        _pairs(fillPlan(spread(testCase), occupied)),
        equals(testCase['expected']),
        reason: 'fillPlan diverged for ${entry.key}',
      );
    }
  });

  test('logDishes writes the same dishes as Python log_dishes', () async {
    expect(cases('log_dishes'), isNotEmpty);
    for (final entry in cases('log_dishes').entries) {
      LogStorageService.resetForTesting(store: MemoryDocStore());
      final storage = LogStorageService.instance;
      final testCase = entry.value as Map<String, dynamic>;
      final seeded = testCase['today'] as List;
      for (final row in seeded.cast<Map<String, dynamic>>()) {
        await storage.logMeal(
          row['desc'] as String,
          _seedNutrition,
          slot: row['slot'] as int,
        );
      }
      final returned = await logDishes(spread(testCase), storage: storage);
      final logged = [
        for (final e in (await storage.todayEntries()).skip(seeded.length))
          [e.desc, e.slot],
      ];
      final reason = 'logDishes diverged for ${entry.key}';
      expect(logged, equals(testCase['expected']), reason: reason);
      expect(_pairs(returned), equals(testCase['expected']), reason: reason);
    }
  });

  test('the twin case really puts two identical dishes in one slot', () {
    // Guards against a regenerated fixture that separates the twins and so
    // silently stops testing the intra-batch dedup.
    final testCase = cases('log_dishes')['twins_share_16'] as Map;
    final input = _pairs(spread(testCase.cast<String, dynamic>()));
    bool isTwin16(List<Object?> p) => p[0] == 'Twin dish' && p[1] == 960;
    expect(input.where(isTwin16), hasLength(2));
    expect(
      (testCase['expected'] as List).cast<List<Object?>>().where(isTwin16),
      hasLength(1),
    );
  });
}
