/// "Fill all with catering" with a later date picked through "Log for later".
///
/// The flow used to hard-code today: picking 24.10 on 23.10 fetched 23.10's
/// delivery and reported "No catering delivery today." Each test pins the
/// *picked* day end to end -- the fetch, the occupancy, and where the entries
/// land -- by reading the log, not a return value.
///
/// The clock is the real one: `logMeal` refuses a `when` in the past against
/// `DateTime.now()`, so the picked day has to be genuinely in the future.
library;

import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/services/kuchnia_fill_flow.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:diet_guard_app/services/kuchnia_queue.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'kuchnia_fill_support.dart';

/// `desc@slot time` for every live entry stored under [day].
Future<List<String>> loggedOn(LogStorageService storage, DateTime day) async {
  final log = await storage.readLog();
  return [
    for (final e in log[localDateKey(day)] ?? const [])
      if (!e.deleted) '${e.desc}@${e.slotMinute} ${e.time.substring(11, 16)}',
  ];
}

void main() {
  late LogStorageService storage;
  late List<DateTime> fetched;
  late KuchniaRefresh delivery;
  late FillAllFlow flow;
  final now = DateTime.now();
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  final dayAfter = DateTime(now.year, now.month, now.day + 2);

  setUp(() {
    storage = freshStorage();
    fetched = [];
    delivery = KuchniaRefresh(dishes: dishes(4));
    flow = FillAllFlow(
      fetch: (day) async {
        fetched.add(day);
        return delivery;
      },
      storage: storage,
    );
  });

  tearDown(LogStorageService.resetForTesting);

  test('fetches the picked day and logs onto it at slot times', () async {
    final first = await flow.tap(day: tomorrow);

    expect(fetched, [tomorrow]);
    expect(first!.message, startsWith('Will log 4'));
    expect(await loggedOn(storage, tomorrow), isEmpty);

    final second = await flow.tap(day: tomorrow);

    expect(
      second!.message,
      'Logged 4 catering dishes for '
      '${localDateKey(tomorrow)}.',
    );
    expect(await loggedOn(storage, tomorrow), [
      'D1@480 08:00',
      'D2@720 12:00',
      'D3@960 16:00',
      'D4@1200 20:00',
    ]);
    expect(await loggedToday(storage), isEmpty);
  });

  test("occupancy is the picked day's, not today's", () async {
    // Today's 08:00 is taken, which must not block tomorrow's 08:00 ...
    await storage.logMeal('eaten today', _kcal, slotMinute: 480);
    // ... while tomorrow's pre-logged 12:00 keeps its meal.
    await storage.logMeal(
      'pre-logged',
      _kcal,
      slotMinute: 720,
      when: tomorrow.add(const Duration(hours: 12)),
    );

    await flow.tap(day: tomorrow);
    await flow.tap(day: tomorrow);

    expect(await loggedOn(storage, tomorrow), [
      'pre-logged@720 12:00',
      'D1@480 08:00',
      'D3@960 16:00',
      'D4@1200 20:00',
    ]);
  });

  test('a plan proposed for one day never confirms onto another', () async {
    await flow.tap(day: tomorrow);
    final outcome = await flow.tap(day: dayAfter);

    expect(fetched, [tomorrow, dayAfter]);
    expect(outcome!.written, isEmpty);
    expect(await loggedOn(storage, tomorrow), isEmpty);
    expect(await loggedOn(storage, dayAfter), isEmpty);
  });

  test('an empty delivery names the picked day', () async {
    delivery = const KuchniaRefresh(dishes: []);

    final outcome = await flow.tap(day: tomorrow);

    expect(
      outcome!.message,
      'No catering delivery on ${localDateKey(tomorrow)}.',
    );
  });

  test('no day still means today', () async {
    await flow.tap();

    expect(fetched, [DateTime(now.year, now.month, now.day)]);
  });

  test("a later day's fetch never marks that day as already fetched", () async {
    // The marker holds one day, read by the automatic "Today's delivery"
    // fetch: recording tomorrow would skip that fetch when tomorrow comes.
    await KuchniaQueueService.initForTesting(MemoryStore());
    addTearDown(KuchniaQueueService.resetForTesting);
    final today = DateTime(now.year, now.month, now.day);
    Future<KuchniaRefresh> fake(DateTime _) async => delivery;

    await fetchAndRecord(tomorrow, fetch: fake);
    expect(KuchniaQueueService.instance.alreadyFetched(tomorrow), isFalse);

    await fetchAndRecord(today, fetch: fake);
    expect(KuchniaQueueService.instance.alreadyFetched(today), isTrue);
  });
}

const _kcal = Nutrition(
  grams: 100,
  kcal: 100,
  proteinG: 1,
  carbsG: 1,
  fatG: 1,
  source: 'manual',
);
