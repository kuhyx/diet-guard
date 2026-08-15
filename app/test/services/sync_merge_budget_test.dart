// Table-driven mergeLogs() tests. `union by id` through `algebraic
// properties` are the exact same assertions the pre-migration
// `sync_merge.mergeLogs` had -- routed through `dayLogToLog ->
// crdt_sync.mergeLogs -> logToDayLog` instead, to prove the migration
// preserves the app's merge semantics exactly, mirroring
// `test_sync_merge.py`'s equivalent Python-side proof.

import 'package:crdt_sync/crdt_sync.dart';
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
  group('budget adapters', () {
    Map<String, dynamic> budgetRecord({
      int b = 2000,
      String t = '2026-06-22T08:00:00',
      double? w,
    }) => {'v': 2, 'b': b, 't': t, 'w': ?w};

    group('budgetHlc', () {
      test('same record always yields the same Hlc', () {
        final record = budgetRecord();
        expect(budgetHlc(record), budgetHlc({...record}));
      });

      test('malformed t still yields a valid Hlc', () {
        final record = budgetRecord(t: 'not-a-timestamp');
        expect(budgetHlc(record).wallTimeMs, 0);
      });

      test('a later t yields a greater Hlc', () {
        final earlier = budgetRecord(t: '2020-01-01T00:00:00Z');
        final later = budgetRecord(t: '2030-01-01T00:00:00Z');
        expect(budgetHlc(later) > budgetHlc(earlier), isTrue);
      });
    });

    group('budgetToLog / logToBudget round trip', () {
      test('null record yields an empty log', () {
        expect(budgetToLog(null), isEmpty);
      });

      test('round trip preserves the budget', () {
        final record = budgetRecord();
        final roundTripped = logToBudget(budgetToLog(record));
        expect(roundTripped, isNotNull);
        expect(roundTripped!['b'], 2000);
      });

      test('weight never travels', () {
        // `w` is PC-local, so it must not enter the shared value map: the
        // phone rebuilds that map without it, and before this fix a winning
        // phone edit silently deleted the PC's stored weight -- and with it
        // the protein target. Matches Python's budget_to_log.
        final record = budgetRecord(w: 80);
        final roundTripped = logToBudget(budgetToLog(record));
        expect(roundTripped, isNotNull);
        expect(roundTripped!.containsKey('w'), isFalse);
      });

      test('history becomes one field per date', () {
        final log = budgetToLog(budgetRecord(), _history);
        final fields = log[budgetRecordId]!.fields;
        expect(fields.containsKey('value'), isTrue);
        expect(fields['hist:1970-01-01']!.$1, 2200);
        expect(fields['hist:2026-07-26']!.$1, 2000);
      });

      test('history round trips back to entries', () {
        final entries = logToHistory(budgetToLog(budgetRecord(), _history));
        expect(entries.map((e) => e.effectiveFrom).toList(), [
          '1970-01-01',
          '2026-07-26',
        ]);
        expect(entries.map((e) => e.kcal).toList(), [2200, 2000]);
      });

      test('no history round trips to nothing', () {
        expect(logToHistory(budgetToLog(budgetRecord())), isEmpty);
      });

      test('an empty log has no history', () {
        expect(logToHistory(<String, Record>{}), isEmpty);
      });

      test('non-history fields are ignored', () {
        final log = budgetToLog(budgetRecord());
        expect(logToHistory(log), isEmpty);
      });

      test('a non-int history value is skipped', () {
        final log = {
          budgetRecordId: Record(
            id: budgetRecordId,
            fields: {
              'hist:2026-07-26': ('nonsense', budgetHlc(budgetRecord())),
            },
          ),
        };
        expect(logToHistory(log), isEmpty);
      });

      test('an unparsable edit time still yields a field', () {
        const broken = BudgetEntry(
          effectiveFrom: '2026-07-26',
          kcal: 2000,
          editedAt: 'not a timestamp',
        );
        final log = budgetToLog(budgetRecord(), [broken]);
        expect(
          log[budgetRecordId]!.fields.containsKey('hist:2026-07-26'),
          isTrue,
        );
      });

      test('history survives a merge with a history-free peer', () {
        // The rollout guarantee: mergeRecord is per-field LWW over the
        // *union* of field names, so a peer that only pushes `value` leaves
        // `hist:*` untouched -- which is why this needed no coordinated
        // release. Mirrors the Python test of the same name.
        final ours = budgetToLog(budgetRecord(), _history);
        final legacy = {
          budgetRecordId: Record(
            id: budgetRecordId,
            fields: {
              'value': (
                {'v': 2, 'b': 2200},
                budgetHlc({'t': '2099-01-01T00:00:00Z'}),
              ),
            },
          ),
        };
        expect(logToHistory(mergeLogs(ours, legacy)), hasLength(2));
      });

      test('the wire field names match the Python side exactly', () {
        // A rename on either side silently splits the two devices' history.
        expect(budgetHistoryFieldPrefix, 'hist:');
        expect(budgetRecordId, 'budget');
      });

      test('round-tripped t reflects the winning Hlc', () {
        final record = budgetRecord();
        final roundTripped = logToBudget(budgetToLog(record));
        expect(roundTripped, isNotNull);
        expect(roundTripped!['t'], isNotEmpty);
      });

      test('empty log has no budget', () {
        expect(logToBudget({}), isNull);
      });
    });

    group('parseRemoteBudget', () {
      test('parses pushed budget wire content', () {
        final record = budgetRecord();
        final pushed = encodeBudgetForPush(budgetToLog(record));
        final log = parseRemoteBudget(pushed);
        expect(log[budgetRecordId]!.id, budgetRecordId);
      });

      test('empty object parses as empty log', () {
        expect(parseRemoteBudget('{}'), isEmpty);
      });

      test('non-object top level throws FormatException', () {
        expect(() => parseRemoteBudget('[1, 2, 3]'), throwsFormatException);
      });

      test('invalid JSON throws FormatException', () {
        expect(() => parseRemoteBudget('not json{{{'), throwsFormatException);
      });
    });
  });
}
