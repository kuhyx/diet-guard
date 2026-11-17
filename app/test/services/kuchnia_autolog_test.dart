/// Catering auto-log: due slots log their dish without a tap, exactly once.
library;

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/services/kuchnia_autolog.dart';
import 'package:diet_guard_app/services/kuchnia_fill.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:diet_guard_app/services/log_entry_lookup.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_merge.dart';
import 'package:crdt_sync/crdt_sync.dart';
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
  slotLabel: '',
  dishId: '${1000 + n}',
);

void main() {
  late LogStorageService storage;
  late int fetches;
  late KuchniaRefresh result;
  late DateTime clock;
  late KuchniaAutoLog autoLog;

  setUp(() {
    storage = freshStorage();
    fetches = 0;
    result = KuchniaRefresh(dishes: [for (var i = 1; i <= 4; i++) _dish(i)]);
    final today = DateTime.now();
    clock = DateTime(today.year, today.month, today.day, 13);
    autoLog = KuchniaAutoLog(
      fetch: (day) async {
        fetches++;
        return result;
      },
      now: () => clock,
    );
  });

  test('logs only the dishes of the due slots, source catering', () async {
    final written = await autoLog.logDue([480, 720]);
    expect(written.map((e) => e.desc), ['D1', 'D2']);
    expect(written.map((e) => e.slotMinute), [480, 720]);
    expect(written.every((e) => e.source == kuchniaSource), isTrue);
    expect(await loggedToday(storage), ['D1@480', 'D2@720']);
  });

  test('ids are the deterministic v5 ids', () async {
    final written = await autoLog.logDue([480]);
    final day = written.single.time.substring(0, 10);
    expect(written.single.id, kuchniaAutologId(day, _dish(1)));
  });

  test('opening twice leaves one entry per dish', () async {
    await autoLog.logDue([480, 720]);
    final second = await KuchniaAutoLog(
      fetch: (day) async => result,
      now: () => clock,
    ).logDue([480, 720]);
    expect(second, isEmpty);
    expect(await loggedToday(storage), ['D1@480', 'D2@720']);
  });

  test('an undone dish is not logged again on the next open', () async {
    final first = await autoLog.logDue([480]);
    await storage.deleteEntry(first.single.id!);
    final again = await KuchniaAutoLog(
      fetch: (day) async => result,
      now: () => clock,
    ).logDue([480]);
    expect(again, isEmpty);
    expect(await storage.todayEntries(), isEmpty);
    expect((await storage.findEntry(first.single.id!))!.deleted, isTrue);
  });

  test('a copy logged on another device merges to one entry', () async {
    final mine = (await autoLog.logDue([480])).single;
    final theirs = FoodEntry(
      id: mine.id,
      time: mine.time.replaceRange(17, 19, '59'),
      desc: mine.desc,
      grams: mine.grams,
      kcal: mine.kcal,
      proteinG: mine.proteinG,
      carbsG: mine.carbsG,
      fatG: mine.fatG,
      source: mine.source,
      slotMinute: mine.slotMinute,
    );
    final merged = logToDayLog(
      mergeLogs(
        dayLogToLog(await storage.readLog()),
        dayLogToLog({
          mine.time.substring(0, 10): [theirs],
        }),
      ),
    );
    expect(merged.values.expand((e) => e), hasLength(1));
  });

  test('later slots find their dish without a second fetch', () async {
    await autoLog.logDue([480]);
    final later = await autoLog.logDue([720]);
    expect(later.map((e) => e.desc), ['D2']);
    expect(fetches, 1);
  });

  test('an empty or failed fetch is retried only after the gap', () async {
    result = const KuchniaRefresh(reason: 'offline');
    expect(await autoLog.logDue([480]), isEmpty);
    expect(await autoLog.logDue([480]), isEmpty);
    expect(fetches, 1);
    clock = clock.add(const Duration(minutes: 11));
    result = KuchniaRefresh(dishes: [_dish(1)]);
    expect((await autoLog.logDue([480])).single.desc, 'D1');
    expect(fetches, 2);
  });

  test('nothing due fetches nothing', () async {
    expect(await autoLog.logDue(const []), isEmpty);
    expect(fetches, 0);
  });

  test('a slot that already holds a meal is left alone', () async {
    await storage.logMeal(
      'manual toast',
      dishNutrition(_dish(1)),
      slotMinute: 480,
    );
    expect(await autoLog.logDue([480]), isEmpty);
  });
}
