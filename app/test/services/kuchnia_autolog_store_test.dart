// The auto-log keeps the day's delivery on disk: offline first.
//
// A restart, or the caterer's panel being down, must not cost the dishes
// already fetched today. These tests pass an in-memory store as the disk.
import 'dart:convert';

import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/kuchnia_autolog.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kuchnia_fill_support.dart';

KuchniaDish _dish(int n) => KuchniaDish(
  name: 'D$n',
  kcal: 100.0 * n,
  proteinG: 10,
  carbsG: 20,
  fatG: 5,
  grams: 300,
  priority: n,
  slotLabel: 'Obiad',
  dishId: '${1000 + n}',
);

/// A disk that is full: every write fails.
class _FullStore implements DocumentStore {
  @override
  Future<String?> read(String name) async => null;

  @override
  Future<void> write(String name, String contents) async =>
      throw Exception('disk');
}

void main() {
  late int fetches;
  late DateTime clock;

  setUp(() {
    freshStorage();
    fetches = 0;
    final today = DateTime.now();
    clock = DateTime(today.year, today.month, today.day, 13);
  });

  KuchniaAutoLog autoLog(DocumentStore store, KuchniaRefresh result) =>
      KuchniaAutoLog(
        store: store,
        fetch: (day) async {
          fetches++;
          return result;
        },
        now: () => clock,
      );

  const down = KuchniaRefresh(reason: 'down');
  final delivered = KuchniaRefresh(dishes: [_dish(1), _dish(2)]);

  test('a restart with the panel down still logs the stored dish', () async {
    final store = MemoryStore();
    await autoLog(store, delivered).logDue([960]);
    expect(fetches, 1);
    final written = await autoLog(store, down).logDue([480]);
    expect(fetches, 1, reason: 'the stored delivery answers, no refetch');
    expect(written.map((e) => e.desc), ['D1']);
  });

  test('a stored delivery of another day is ignored', () async {
    final store = MemoryStore();
    store.documents[KuchniaAutoLog.documentName] = jsonEncode({
      'day': '1999-01-01',
      'dishes': [_dish(1).toJson()],
    });
    expect(await autoLog(store, down).logDue([480]), isEmpty);
    expect(fetches, 1);
  });

  test('a malformed stored document is ignored', () async {
    final store = MemoryStore();
    for (final raw in [
      'not json',
      '[]',
      jsonEncode({'day': localDateKey(clock), 'dishes': 'x'}),
      jsonEncode({
        'day': localDateKey(clock),
        'dishes': [
          {'name': 'D1'},
        ],
      }),
    ]) {
      store.documents[KuchniaAutoLog.documentName] = raw;
      expect(await autoLog(store, down).logDue([480]), isEmpty, reason: raw);
    }
    expect(fetches, 4);
  });

  test('non-map items in a stored delivery are skipped', () async {
    final store = MemoryStore();
    store.documents[KuchniaAutoLog.documentName] = jsonEncode({
      'day': localDateKey(clock),
      'dishes': [1, _dish(1).toJson()],
    });
    final written = await autoLog(store, down).logDue([480]);
    expect(written.map((e) => e.desc), ['D1']);
    expect(fetches, 0);
  });

  test('a failing disk does not break logging', () async {
    final written = await autoLog(_FullStore(), delivered).logDue([480]);
    expect(written.map((e) => e.desc), ['D1']);
  });

  test('toJson and fromJson round-trip every field', () {
    final dish = _dish(3);
    final back = KuchniaDish.fromJson(dish.toJson());
    expect(back.toJson(), dish.toJson());
    final noId = Map<String, Object?>.of(dish.toJson())..remove('dish_id');
    expect(KuchniaDish.fromJson(noId).dishId, '');
  });
}
