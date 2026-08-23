/// The Dart half of the cross-language catering parity gate.
///
/// `diet_guard/tests/test_kuchnia_parity.py` asserts the *same* expectations
/// against the *same* `tests/fixtures/kuchnia_day.json`. Two independently
/// written suites from the same prose is not a gate -- one shared input with
/// one shared expected result is, because a divergence has to surface as a
/// failure on one side rather than as two self-consistent implementations.
///
/// What the parity protects, per `docs/kuchnia-wikinga.md`:
///
/// * **Slot assignment.** A slot one device offers while the other does not is
///   a checkpoint that can never be satisfied -- a permanent lock.
/// * **Which dishes are dropped.** If the two sides disagree, each re-adds
///   what the other dropped, `add_manual_entry` restamps `t` unconditionally,
///   and the curated bank republishes to every peer on every refresh.
/// * **Bank keys and record values**, including their JSON *types*.
///
/// `dart:io` is fine here: the repo invariant only scans `lib/`, and
/// `flutter test` runs on the VM.
library;

import 'dart:convert';
import 'dart:io';

import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/services/kuchnia_parse.dart';
import 'package:diet_guard_app/services/kuchnia_spread.dart';
import 'package:flutter_test/flutter_test.dart';

/// The repo root, found by walking up from the package directory.
///
/// Mirrors `repo_invariants_test.dart`'s approach so the test works whatever
/// working directory `flutter test` picks.
Directory get _repoRoot {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate app/ from ${Directory.current.path}');
    }
    dir = parent;
  }
  // `dir` is app/; the fixture is shared, so it lives at the repo root.
  return dir.parent;
}

File get _fixtureFile =>
    File('${_repoRoot.path}/tests/fixtures/kuchnia_day.json');

void main() {
  late Map<String, dynamic> fixture;
  late Map<String, dynamic> expected;
  late List<KuchniaDish> dishes;

  setUpAll(() {
    fixture =
        jsonDecode(_fixtureFile.readAsStringSync()) as Map<String, dynamic>;
    expected = fixture['expected'] as Map<String, dynamic>;
    dishes = parseMenu(fixture['payload']);
  });

  test('the shared fixture is present', () {
    // Asserted explicitly so a relocation fails with a clear reason rather
    // than as a confusing cast error inside another test.
    expect(
      _fixtureFile.existsSync(),
      isTrue,
      reason: 'shared parity fixture missing at ${_fixtureFile.path}. It is '
          'read by both flutter test and pytest; regenerate with '
          'scripts/build_kuchnia_fixture.py.',
    );
  });

  test('parsed dishes match the shared expectation', () {
    final actual = [
      for (final dish in dishes)
        {
          'name': dish.name,
          'kcal': dish.kcal,
          'protein_g': dish.proteinG,
          'carbs_g': dish.carbsG,
          'fat_g': dish.fatG,
          'grams': dish.grams,
          'priority': dish.priority,
          'slot_label': dish.slotLabel,
        },
    ];
    expect(actual, equals(expected['dishes']));
  });

  test('the same meals are dropped on both sides', () {
    // Vacuous against a clean capture, which is why the fixture carries a
    // per-100 g mix-up, an absurd portion, a stringly-typed number, a non-map
    // entry and a meal with no nutrition at all.
    final total = (fixture['payload'] as Map)['deliveryMenuMeal'] as List;
    expect(total.length - dishes.length, equals(expected['dropped_count']));
    expect(expected['dropped_count'], greaterThan(0));
  });

  test('slot assignment matches for every configured schedule', () {
    final slotCases = expected['slots'] as Map<String, dynamic>;
    for (final entry in slotCases.entries) {
      var key = entry.key;
      var subject = dishes;
      if (key.startsWith('first_three_')) {
        subject = dishes.take(3).toList();
        key = key.substring('first_three_'.length);
      }
      final hours = [for (final part in key.split(',')) int.parse(part)];
      final actual = [
        for (final item in assignSlots(subject, hours)) item.slot,
      ];
      expect(
        actual,
        equals(entry.value),
        reason: 'slot assignment diverged for ${entry.key}',
      );
    }
  });

  test('slot ordering is total, so the twin-dish pair cannot reshuffle', () {
    // Dart's List.sort is not stable and Python's sorted is, so two dishes
    // sharing both priority and name are what force the comparator to be
    // total. Run repeatedly: an unstable sort need not misbehave every time.
    for (var attempt = 0; attempt < 5; attempt++) {
      final ordered = assignSlots(parseMenu(fixture['payload']), const [
        8,
        12,
        16,
        20,
      ]);
      expect(
        [for (final item in ordered) item.dish.name],
        equals(expected['slot_order']),
      );
    }
  });

  test('bank keys match', () {
    expect(
      [for (final dish in dishes) dish.bankKey],
      equals(expected['bank_keys']),
    );
  });

  test('bank records match by value', () {
    // Numeric comparison, not string: `270 == 270.0` must be true here exactly
    // as it is in Python's `_matches`, or every phone refresh rewrites the
    // whole curated bank.
    expect(
      [for (final dish in dishes) dish.toBankRecord()],
      equals(expected['bank_records']),
    );
  });

  test('bank records encode byte-identically to the Python ones', () {
    // The real divergence risk is int-vs-double at the JSON boundary:
    // jsonEncode(435) emits `435` where Python emits `435.0`. Comparing the
    // encoded text (canonical key order on both sides) is what catches it;
    // the value comparison above would not.
    final expectedRecords = expected['bank_records'] as List;
    for (var i = 0; i < dishes.length; i++) {
      final actual = dishes[i].toBankRecord();
      final wanted = (expectedRecords[i] as Map).cast<String, dynamic>();
      final sortedKeys = actual.keys.toList()..sort();
      String canonical(Map<String, dynamic> record) => jsonEncode({
        for (final key in sortedKeys) key: record[key],
      });
      expect(
        canonical(actual),
        equals(canonical(wanted)),
        reason: 'record ${i + 1} (${dishes[i].name}) encodes differently to '
            'the Python-banked record; check int vs double.',
      );
    }
  });

  test('macros bank as doubles and count as an int', () {
    for (final dish in dishes) {
      final record = dish.toBankRecord();
      for (final key in ['kcal', 'protein_g', 'carbs_g', 'fat_g', 'grams']) {
        expect(
          record[key],
          isA<double>(),
          reason: '$key must bank as a double, or its JSON loses the ".0"',
        );
      }
      expect(record['count'], isA<int>());
    }
  });

  test('a stringly-typed number is coerced to 0, never parsed', () {
    // Pins the `as_float` contract. `double.tryParse` here would keep a dish
    // the PC drops, and then each device re-adds what the other removed.
    expect(asDouble('435'), equals(0.0));
    expect(asDouble(true), equals(0.0));
    expect(asDouble(null), equals(0.0));
    expect(asDouble(435), equals(435.0));
    expect(asDouble(435.5), equals(435.5));
  });

  test('the energy tolerance is 0.35, not the "~1%" in the prose', () {
    // Porting 0.01 would drop dishes the PC keeps, and each side would re-add
    // what the other dropped -- the republish flood.
    expect(kuchniaEnergyTolerance, equals(0.35));
  });
}
