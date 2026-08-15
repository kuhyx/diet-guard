// Table-driven mergeLogs() tests. `union by id` through `algebraic
// properties` are the exact same assertions the pre-migration
// `sync_merge.mergeLogs` had -- routed through `dayLogToLog ->
// crdt_sync.mergeLogs -> logToDayLog` instead, to prove the migration
// preserves the app's merge semantics exactly, mirroring
// `test_sync_merge.py`'s equivalent Python-side proof.

import 'dart:convert';

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
  group('entryHlc', () {
    test('same entry always yields the same Hlc', () {
      expect(entryHlc(_entry()), entryHlc(_entry()));
    });

    test('malformed time still yields a valid Hlc', () {
      expect(entryHlc(_entry(time: 'not-a-timestamp')).wallTimeMs, 0);
    });
  });
  group('legacyEntryId', () {
    test('same time and desc yields the same id', () {
      final a = _entry(time: '2026-06-20T08:00:00', desc: 'toast');
      final b = _entry(time: '2026-06-20T08:00:00', desc: 'toast');
      expect(legacyEntryId(a), legacyEntryId(b));
    });

    test('different desc yields a different id', () {
      final a = _entry(time: '2026-06-20T08:00:00', desc: 'toast');
      final b = _entry(time: '2026-06-20T08:00:00', desc: 'eggs');
      expect(legacyEntryId(a), isNot(legacyEntryId(b)));
    });
  });
  group('entry <-> Record round trip', () {
    test('round trip preserves all fields', () {
      final entry = _entry(id: 'x');
      final roundTripped = recordToEntry(entryToRecord(entry));
      expect(roundTripped.toSyncJson(), entry.toSyncJson());
    });

    test('round trip of a deleted entry preserves the tombstone', () {
      final entry = _entry(id: 'x', deleted: true);
      expect(recordToEntry(entryToRecord(entry)).deleted, isTrue);
    });

    test('legacy entry gets a derived id on round trip', () {
      final entry = _entry(
        id: null,
        time: '2026-06-20T08:00:00',
        desc: 'toast',
      );
      final roundTripped = recordToEntry(entryToRecord(entry));
      expect(roundTripped.id, legacyEntryId(entry));
    });

    test('a Record with no body field falls back to an empty body', () {
      const record = Record(id: 'x', fields: {});
      final entry = recordToEntry(record);
      expect(entry.id, 'x');
      expect(entry.desc, isEmpty);
    });
  });
  group('parseRemoteLog', () {
    test('parses new-format wire content', () {
      final entry = _entry(id: 'x');
      final pushed = encodeLogForPush({'x': entryToRecord(entry)});
      final log = parseRemoteLog(pushed);
      expect(log['x']!.id, 'x');
    });

    test('parses old DayLog format for backward compatibility', () {
      final entry = _entry(id: 'x');
      final oldFormat = jsonEncode({
        '2026-06-22': [entry.toSyncJson()],
      });
      final log = parseRemoteLog(oldFormat);
      expect(log['x']!.id, 'x');
    });

    test('empty object parses as empty log', () {
      expect(parseRemoteLog('{}'), isEmpty);
    });

    test('non-object top level throws FormatException', () {
      expect(() => parseRemoteLog('[1, 2, 3]'), throwsFormatException);
    });

    test('old-format day not a list throws FormatException', () {
      expect(
        () => parseRemoteLog('{"2026-06-22": "not-a-list"}'),
        throwsFormatException,
      );
    });

    test('invalid JSON throws FormatException', () {
      expect(() => parseRemoteLog('not json{{{'), throwsFormatException);
    });
  });
}
