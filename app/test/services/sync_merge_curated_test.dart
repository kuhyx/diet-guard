// Table-driven mergeLogs() tests. `union by id` through `algebraic
// properties` are the exact same assertions the pre-migration
// `sync_merge.mergeLogs` had -- routed through `dayLogToLog ->
// crdt_sync.mergeLogs -> logToDayLog` instead, to prove the migration
// preserves the app's merge semantics exactly, mirroring
// `test_sync_merge.py`'s equivalent Python-side proof.

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/budget_schedule.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_merge.dart';
import 'package:flutter_test/flutter_test.dart';

FoodEntry _entry({
  String? id = 'id-1',
  String time = '2026-06-22T08:00:00',
  String desc = 'oatmeal',
  bool deleted = false,
}) => FoodEntry(
  id: id,
  time: time,
  desc: desc,
  grams: 200,
  kcal: 300,
  proteinG: 10,
  carbsG: 50,
  fatG: 5,
  source: 'manual',
  deleted: deleted,
);

DayLog _mergeDaylogs(DayLog a, DayLog b) =>
    logToDayLog(mergeLogs(dayLogToLog(a), dayLogToLog(b)));

const _history = [
  BudgetEntry(
    effectiveFrom: '1970-01-01',
    kcal: 2200,
    editedAt: '2026-07-13T21:15:09.000Z',
  ),
  BudgetEntry(
    effectiveFrom: '2026-07-26',
    kcal: 2000,
    editedAt: '2026-07-26T10:00:00.000Z',
  ),
];

void main() {
  group('curated food-bank adapters', () {
    // Mirror of `test_sync_merge.py`'s TestManualBankAdapters. A divergence
    // here means a food curated on one device never reaches the other.
    FoodBankRecord skyr({double kcal = 120, String? t}) => FoodBankRecord(
      desc: 'Skyr',
      kcal: kcal,
      proteinG: 20,
      carbsG: 5,
      fatG: 0.5,
      grams: 150,
      count: 0,
      editedAt: t ?? '2026-07-26T10:00:00.000Z',
    );

    test('round trips a record', () {
      final back = logToManualBank(manualBankToLog({'skyr': skyr()}));
      expect(back['skyr']!.desc, 'Skyr');
      expect(back['skyr']!.kcal, 120);
    });

    test('the edit stamp does not travel inside the body', () {
      final log = manualBankToLog({'skyr': skyr()});
      expect(
        (log['skyr']!.fields['body']!.$1! as Map).containsKey('t'),
        isFalse,
      );
    });

    test('edit time is reconstructed from the Hlc', () {
      final back = logToManualBank(manualBankToLog({'skyr': skyr()}));
      expect(back['skyr']!.editedAt, isNotNull);
    });

    test('a missing edit stamp falls back to the epoch', () {
      final log = manualBankToLog({
        'skyr': const FoodBankRecord(
          desc: 'Skyr',
          kcal: 1,
          proteinG: 0,
          carbsG: 0,
          fatG: 0,
          grams: 0,
          count: 0,
        ),
      });
      expect(log['skyr']!.fields['body']!.$2.wallTimeMs, 0);
    });

    test('a newer edit wins the merge', () {
      final older = manualBankToLog({'skyr': skyr()});
      final newer = manualBankToLog({
        'skyr': skyr(kcal: 999, t: '2999-01-01T00:00:00.000Z'),
      });
      expect(logToManualBank(mergeLogs(older, newer))['skyr']!.kcal, 999);
    });

    test('different foods union rather than replace', () {
      final a = manualBankToLog({'skyr': skyr()});
      final b = manualBankToLog({
        'kefir': const FoodBankRecord(
          desc: 'Kefir',
          kcal: 60,
          proteinG: 3,
          carbsG: 4,
          fatG: 2,
          grams: 100,
          count: 0,
          editedAt: '2026-07-26T10:00:00.000Z',
        ),
      });
      expect(logToManualBank(mergeLogs(a, b)).keys.toSet(), {'skyr', 'kefir'});
    });

    test('a non-map body is skipped on read', () {
      final log = {
        'skyr': Record(
          id: 'skyr',
          fields: {
            'body': ('nope', budgetHlc(const {'t': ''})),
          },
        ),
      };
      expect(logToManualBank(log), isEmpty);
    });

    test('a tombstoned record is dropped on read', () {
      final log = {
        'skyr': Record(
          id: 'skyr',
          fields: {
            'body': (skyr().toJson(), budgetHlc(const {'t': ''})),
          },
          deleted: true,
        ),
      };
      expect(logToManualBank(log), isEmpty);
    });

    test('parses pushed wire content', () {
      final wire = encodeManualBankForPush(manualBankToLog({'skyr': skyr()}));
      expect(parseRemoteManualBank(wire).containsKey('skyr'), isTrue);
    });

    test('non-object top level throws FormatException', () {
      expect(() => parseRemoteManualBank('[1,2,3]'), throwsFormatException);
    });

    test('the wire shape matches the Python side', () {
      // Python uses the same `body` field name and the same normalized-name
      // record id; a rename on either side silently splits the two banks.
      final log = manualBankToLog({'skyr': skyr()});
      expect(log['skyr']!.id, 'skyr');
      expect(log['skyr']!.fields.keys.toList(), ['body']);
    });
  });
}
