// Table-driven mergeLogs() tests. `union by id` through `algebraic
// properties` are the exact same assertions the pre-migration
// `sync_merge.mergeLogs` had -- routed through `dayLogToLog ->
// crdt_sync.mergeLogs -> logToDayLog` instead, to prove the migration
// preserves the app's merge semantics exactly, mirroring
// `test_sync_merge.py`'s equivalent Python-side proof.

import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/food_entry.dart';
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

void main() {
  group('union by id', () {
    test('disjoint logs union into one', () {
      final a = {
        '2026-06-22': [_entry(id: 'a', time: '2026-06-22T08:00:00')],
      };
      final b = {
        '2026-06-22': [_entry(id: 'b', time: '2026-06-22T12:00:00')],
      };
      final merged = _mergeDaylogs(a, b);
      expect(merged['2026-06-22']!.map((e) => e.id).toSet(), {'a', 'b'});
    });

    test('same id in both logs is not duplicated', () {
      final shared = _entry(id: 'shared');
      final merged = _mergeDaylogs(
        {
          '2026-06-22': [shared],
        },
        {
          '2026-06-22': [shared],
        },
      );
      expect(merged['2026-06-22'], hasLength(1));
    });

    test('legacy entries without id dedup by time and desc', () {
      final legacyA = _entry(
        id: null,
        time: '2026-06-20T08:00:00',
        desc: 'toast',
      );
      final legacyB = _entry(
        id: null,
        time: '2026-06-20T08:00:00',
        desc: 'toast',
      );
      final merged = _mergeDaylogs(
        {
          '2026-06-20': [legacyA],
        },
        {
          '2026-06-20': [legacyB],
        },
      );
      expect(merged['2026-06-20'], hasLength(1));
    });

    test('legacy and id entries with different keys both survive', () {
      final legacy = _entry(
        id: null,
        time: '2026-06-20T08:00:00',
        desc: 'toast',
      );
      final withId = _entry(id: 'x', time: '2026-06-20T09:00:00', desc: 'eggs');
      final merged = _mergeDaylogs(
        {
          '2026-06-20': [legacy],
        },
        {
          '2026-06-20': [withId],
        },
      );
      expect(merged['2026-06-20'], hasLength(2));
    });
  });

  group('tombstone wins', () {
    test('tombstone beats a non-deleted copy either order', () {
      final normal = _entry(id: 'x');
      final tombstoned = _entry(id: 'x', deleted: true);

      final forward = _mergeDaylogs(
        {
          '2026-06-22': [normal],
        },
        {
          '2026-06-22': [tombstoned],
        },
      );
      final backward = _mergeDaylogs(
        {
          '2026-06-22': [tombstoned],
        },
        {
          '2026-06-22': [normal],
        },
      );

      expect(forward['2026-06-22']!.single.deleted, isTrue);
      expect(backward['2026-06-22']!.single.deleted, isTrue);
    });

    test('two tombstoned copies stay tombstoned', () {
      final tombstoned = _entry(id: 'x', deleted: true);
      final merged = _mergeDaylogs(
        {
          '2026-06-22': [tombstoned],
        },
        {
          '2026-06-22': [_entry(id: 'x', deleted: true)],
        },
      );
      expect(merged['2026-06-22']!.single.deleted, isTrue);
    });
  });

  group('rebucketing and ordering', () {
    test(
      "entry is filed under its own time's date, not the arrival bucket",
      () {
        final misfiled = _entry(id: 'x', time: '2026-06-21T23:00:00');
        final merged = _mergeDaylogs({
          '2026-06-22': [misfiled],
        }, {});
        expect(merged.keys, ['2026-06-21']);
        expect(merged['2026-06-21']!.single.id, 'x');
      },
    );

    test(
      'an entry with a time shorter than a date key buckets under the '
      'raw time instead of crashing',
      () {
        final short = _entry(id: 'x', time: '2026');
        final merged = _mergeDaylogs({
          '2026-06-22': [short],
        }, {});
        expect(merged.keys, ['2026']);
      },
    );

    test("a day's entries are sorted oldest-first", () {
      final late = _entry(id: 'late', time: '2026-06-22T20:00:00');
      final early = _entry(id: 'early', time: '2026-06-22T08:00:00');
      final merged = _mergeDaylogs(
        {
          '2026-06-22': [late],
        },
        {
          '2026-06-22': [early],
        },
      );
      expect(merged['2026-06-22']!.map((e) => e.id).toList(), [
        'early',
        'late',
      ]);
    });
  });

  group('algebraic properties', () {
    test('merge is commutative', () {
      final a = {
        '2026-06-22': [_entry(id: 'a')],
      };
      final b = {
        '2026-06-22': [_entry(id: 'b', time: '2026-06-22T09:00:00')],
      };
      final ab = _mergeDaylogs(a, b);
      final ba = _mergeDaylogs(b, a);
      expect(
        ab['2026-06-22']!.map((e) => e.id).toList(),
        ba['2026-06-22']!.map((e) => e.id).toList(),
      );
    });

    test('merge is idempotent', () {
      final canonical = {
        '2026-06-22': [_entry(id: 'a')],
      };
      final merged = _mergeDaylogs(canonical, canonical);
      expect(merged['2026-06-22']!.map((e) => e.id).toList(), ['a']);
    });

    test('merging with an empty log is a no-op', () {
      final log = {
        '2026-06-22': [_entry(id: 'a')],
      };
      expect(_mergeDaylogs(log, {}).keys, log.keys);
      expect(_mergeDaylogs({}, log).keys, log.keys);
    });

    test('merging two empty logs is empty', () {
      expect(_mergeDaylogs({}, {}), isEmpty);
    });
  });

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
