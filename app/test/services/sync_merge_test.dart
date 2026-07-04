// Table-driven `mergeLogs()` tests mirroring `test_sync_merge.py` exactly
// (same cases, same expected outcomes), so both implementations are provably
// testing the same algorithm.

import 'package:diet_guard_app/models/food_entry.dart';
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

void main() {
  group('union by id', () {
    test('disjoint logs union into one', () {
      final a = {
        '2026-06-22': [_entry(id: 'a', time: '2026-06-22T08:00:00')],
      };
      final b = {
        '2026-06-22': [_entry(id: 'b', time: '2026-06-22T12:00:00')],
      };
      final merged = mergeLogs(a, b);
      expect(merged['2026-06-22']!.map((e) => e.id).toSet(), {'a', 'b'});
    });

    test('same id in both logs is not duplicated', () {
      final shared = _entry(id: 'shared');
      final merged = mergeLogs(
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
      final merged = mergeLogs(
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
      final merged = mergeLogs(
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

      final forward = mergeLogs(
        {
          '2026-06-22': [normal],
        },
        {
          '2026-06-22': [tombstoned],
        },
      );
      final backward = mergeLogs(
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
      final merged = mergeLogs(
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
        final merged = mergeLogs({
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
        // Dart's substring throws past the string length, unlike Python's
        // forgiving slice -- this only matters for malformed/legacy data.
        final short = _entry(id: 'x', time: '2026');
        final merged = mergeLogs({
          '2026-06-22': [short],
        }, {});
        expect(merged.keys, ['2026']);
      },
    );

    test("a day's entries are sorted oldest-first", () {
      final late = _entry(id: 'late', time: '2026-06-22T20:00:00');
      final early = _entry(id: 'early', time: '2026-06-22T08:00:00');
      final merged = mergeLogs(
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
      final ab = mergeLogs(a, b);
      final ba = mergeLogs(b, a);
      expect(
        ab['2026-06-22']!.map((e) => e.id).toList(),
        ba['2026-06-22']!.map((e) => e.id).toList(),
      );
    });

    test('merge is idempotent', () {
      final canonical = {
        '2026-06-22': [_entry(id: 'a')],
      };
      final merged = mergeLogs(canonical, canonical);
      expect(merged['2026-06-22']!.map((e) => e.id).toList(), ['a']);
    });

    test('merging with an empty log is a no-op', () {
      final log = {
        '2026-06-22': [_entry(id: 'a')],
      };
      expect(mergeLogs(log, {}).keys, log.keys);
      expect(mergeLogs({}, log).keys, log.keys);
    });

    test('merging two empty logs is empty', () {
      expect(mergeLogs({}, {}), isEmpty);
    });
  });
}
