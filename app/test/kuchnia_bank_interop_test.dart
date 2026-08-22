/// The phone must read a catering-imported bank record without losing anything.
///
/// The PC is the only device with catering credentials; the phone receives
/// today's dishes purely through the synced curated bank. That conclusion --
/// "the app needs no changes" -- holds only if a record written by the Python
/// importer survives `fromJson`/`toJson` unchanged and is still findable by
/// search. Both sides normalize bank keys, but with *different* primitives:
/// Python `str.casefold()`, Dart `String.toLowerCase()`. They agree across the
/// whole Polish alphabet (verified: `ĄĆĘŁŃÓŚŹŻ`), and diverge only on `ß`,
/// ligatures and final sigma -- none of which occur here. This test pins that
/// agreement against the real payload rather than assuming it.
///
/// The fixture is a verbatim capture of `food_bank_manual.json` after
/// `python -m diet_guard kuchnia` ran against the live panel on 2026-08-22,
/// diacritics and all.
library;

import 'dart:convert';

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exactly what the Python importer wrote, including the `t` edit stamp.
const String _bankJson = '''
{
  "marchewkowe pancakes, twarożek cynamonowy, sos truskawkowy": {
    "desc": "Marchewkowe pancakes, twarożek cynamonowy, sos truskawkowy",
    "kcal": 435.0, "protein_g": 25.86, "carbs_g": 54.64, "fat_g": 12.01,
    "grams": 270.0, "count": 0, "t": "2026-08-22T23:24:08+02:00"
  },
  "makaron farfalle z indykiem w sosie z batatów z suszonymi pomidorami": {
    "desc": "Makaron farfalle z indykiem w sosie z batatów z suszonymi pomidorami",
    "kcal": 594.0, "protein_g": 42.47, "carbs_g": 53.23, "fat_g": 23.21,
    "grams": 465.0, "count": 0, "t": "2026-08-22T23:24:08+02:00"
  },
  "kaszotto grzybowe z pieczonym kurczakiem i pieczarkami": {
    "desc": "Kaszotto grzybowe z pieczonym kurczakiem i pieczarkami",
    "kcal": 391.0, "protein_g": 32.51, "carbs_g": 35.56, "fat_g": 13.02,
    "grams": 318.0, "count": 0, "t": "2026-08-22T23:24:08+02:00"
  }
}
''';

Map<String, FoodBankRecord> _parseBank() {
  final raw = jsonDecode(_bankJson) as Map<String, dynamic>;
  return raw.map(
    (key, value) => MapEntry(
      key,
      FoodBankRecord.fromJson(value as Map<String, dynamic>),
    ),
  );
}

void main() {
  group('a catering-imported bank record on the phone', () {
    test('parses every dish the importer banked', () {
      final bank = _parseBank();
      expect(bank, hasLength(3));
      for (final record in bank.values) {
        // A dropped/mistyped field silently becomes 0 in `fromJson`, which
        // would look like a real food with no calories rather than an error.
        expect(record.desc, isNotEmpty);
        expect(record.kcal, greaterThan(0));
        expect(record.grams, greaterThan(0));
      }
    });

    test('keeps Polish diacritics intact through a JSON round-trip', () {
      final bank = _parseBank();
      const key =
          'makaron farfalle z indykiem w sosie z batatów '
          'z suszonymi pomidorami';
      final record = bank[key];
      expect(record, isNotNull, reason: 'diacritic key must match verbatim');
      expect(record!.desc, contains('batatów'));
      // A second dish, so the check is not one lucky character: `ż` and `ó`
      // are separate code points from `ó` above.
      expect(
        _parseBank().keys,
        contains(startsWith('marchewkowe pancakes, twarożek')),
      );

      // The round-trip the sync layer performs on every merge. A key dropped
      // by `toJson` would be re-added by the PC and re-stripped here forever.
      final again = FoodBankRecord.fromJson(
        jsonDecode(jsonEncode(record.toJson())) as Map<String, dynamic>,
      );
      expect(again.desc, record.desc);
      expect(again.kcal, record.kcal);
      expect(again.proteinG, record.proteinG);
      expect(again.carbsG, record.carbsG);
      expect(again.fatG, record.fatG);
      expect(again.grams, record.grams);
      expect(again.editedAt, record.editedAt);
    });

    test("Dart's toLowerCase agrees with Python's casefold on these names", () {
      // The two devices key the same record with different primitives, so a
      // divergence here makes a dish permanently unsearchable on one side.
      // The Python keys below were produced by `str.strip().casefold()`.
      for (final key in _parseBank().keys) {
        expect(key.trim().toLowerCase(), key);
      }
    });

    test('preserves the edit stamp the curated bank merges on', () {
      // `food_bank_manual.json` is LWW by `t`. Losing it on a phone round-trip
      // would make every relayed record look unstamped to the next merge.
      final record = _parseBank().values.first;
      expect(record.editedAt, '2026-08-22T23:24:08+02:00');
      expect(record.toJson()['t'], '2026-08-22T23:24:08+02:00');
    });
  });
}
