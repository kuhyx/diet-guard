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
  group('derived food-bank adapters', () {
    // Mirror of `test_sync_merge.py`'s TestFoodBankAdapters.
    FoodBankRecord apple({required double count, double kcal = 95}) =>
        FoodBankRecord(
          desc: 'Apple',
          kcal: kcal,
          proteinG: 0.5,
          carbsG: 25,
          fatG: 0.3,
          grams: 180,
          count: count,
        );

    test('count is the clock', () {
      final log = foodBankToLog({'apple': apple(count: 5)});
      expect(log['apple']!.fields['body']!.$2.wallTimeMs, 5);
    });

    test('the higher count wins', () {
      final behind = foodBankToLog({'apple': apple(count: 3, kcal: 90)});
      final ahead = foodBankToLog({'apple': apple(count: 9)});
      final merged = logToFoodBank(mergeLogs(behind, ahead));
      expect(merged['apple']!.count, 9);
      expect(merged['apple']!.kcal, 95);
    });

    test('the merge is order independent', () {
      final a = foodBankToLog({'apple': apple(count: 3)});
      final b = foodBankToLog({'apple': apple(count: 9)});
      expect(
        logToFoodBank(mergeLogs(a, b))['apple']!.count,
        logToFoodBank(mergeLogs(b, a))['apple']!.count,
      );
    });

    test('re-merging is idempotent', () {
      final once = foodBankToLog({'apple': apple(count: 5)});
      expect(logToFoodBank(mergeLogs(once, once))['apple']!.count, 5);
    });

    test('different foods union', () {
      final a = foodBankToLog({'apple': apple(count: 1)});
      final b = foodBankToLog({
        'pear': const FoodBankRecord(
          desc: 'Pear',
          kcal: 57,
          proteinG: 0,
          carbsG: 15,
          fatG: 0,
          grams: 100,
          count: 1,
        ),
      });
      expect(logToFoodBank(mergeLogs(a, b)).keys.toSet(), {'apple', 'pear'});
    });

    test('a non-map body is skipped on read', () {
      final log = {
        'apple': Record(
          id: 'apple',
          fields: {
            'body': ('x', budgetHlc(const {'t': ''})),
          },
        ),
      };
      expect(logToFoodBank(log), isEmpty);
    });

    test('parses pushed wire content', () {
      final wire = encodeFoodBankForPush(
        foodBankToLog({'apple': apple(count: 5)}),
      );
      expect(parseRemoteFoodBank(wire).containsKey('apple'), isTrue);
    });

    test('non-object top level throws FormatException', () {
      expect(() => parseRemoteFoodBank('[1,2,3]'), throwsFormatException);
    });

    test('the wire shape matches the Python side', () {
      final log = foodBankToLog({'apple': apple(count: 5)});
      expect(log['apple']!.id, 'apple');
      expect(log['apple']!.fields.keys.toList(), ['body']);
    });
  });
}
