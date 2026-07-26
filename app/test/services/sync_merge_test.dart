// Table-driven mergeLogs() tests. `union by id` through `algebraic
// properties` are the exact same assertions the pre-migration
// `sync_merge.mergeLogs` had -- routed through `dayLogToLog ->
// crdt_sync.mergeLogs -> logToDayLog` instead, to prove the migration
// preserves the app's merge semantics exactly, mirroring
// `test_sync_merge.py`'s equivalent Python-side proof.

import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/budget_schedule.dart';
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
      final ahead = foodBankToLog({'apple': apple(count: 9, kcal: 95)});
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
        'pear': FoodBankRecord(
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
        (log['skyr']!.fields['body']!.$1 as Map).containsKey('t'),
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
        'kefir': FoodBankRecord(
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

  group('budget adapters', () {
    Map<String, dynamic> budgetRecord({
      int b = 2000,
      String t = '2026-06-22T08:00:00',
      double? w,
    }) => {'v': 2, 'b': b, 't': t, if (w != null) 'w': w};

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
