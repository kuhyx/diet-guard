/// The delivered-dish queue and its refresh guard.
///
/// Two failure modes here are invisible to an "is the dish offered?" test,
/// which is why these assert on *counts*:
///
/// * **The queue must survive a submit.** On the PC this regressed into a dead
///   letter once: every dish after the first stayed queued behind another
///   click. Asserting that a dish was offered passes while that misbehaves;
///   asserting that dish 2 is next *immediately after* dish 1 is logged does
///   not.
/// * **The automatic refresh must be guarded.** Each refresh is a login plus a
///   three-request walk against a third party, and the log-flow trigger can
///   fire many times a day. The test counts fetches, not results.
library;

import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/kuchnia_queue.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory store, so these tests need no plugin channel.
class _MemoryStore implements DocumentStore {
  final Map<String, String> documents = {};

  @override
  Future<String?> read(String name) async => documents[name];

  @override
  Future<void> write(String name, String contents) async {
    documents[name] = contents;
  }
}

KuchniaDish _dish(String name, int priority) => KuchniaDish(
  name: name,
  kcal: 400,
  proteinG: 25,
  carbsG: 45,
  fatG: 12,
  grams: 300,
  priority: priority,
  slotLabel: 'Obiad',
);

void main() {
  late _MemoryStore store;
  final today = DateTime(2026, 8, 23);

  setUp(() async {
    store = _MemoryStore();
    await KuchniaQueueService.initForTesting(store);
  });

  tearDown(KuchniaQueueService.resetForTesting);

  group('the queue survives a submit', () {
    test('logging dish 1 leaves dish 2 as the next offer', () {
      final dishes = [_dish('Pancakes', 1), _dish('Kaszotto', 2)];
      KuchniaQueueService.instance.offer(dishes);
      expect(KuchniaQueueService.next!.name, 'Pancakes');
      expect(KuchniaQueueService.remaining, 2);

      KuchniaQueueService.instance.markLogged(dishes.first);

      // The whole delivery must walk on one tap per dish. If this ever reads
      // null, the "(N more to go)" promise is a dead letter again.
      expect(KuchniaQueueService.next!.name, 'Kaszotto');
      expect(KuchniaQueueService.remaining, 1);
    });

    test('the last dish empties the queue', () {
      final dish = _dish('Pancakes', 1);
      KuchniaQueueService.instance.offer([dish]);
      KuchniaQueueService.instance.markLogged(dish);
      expect(KuchniaQueueService.next, isNull);
      expect(KuchniaQueueService.remaining, 0);
    });

    test('a dish left over when the last slot unlocks is still queued', () {
      // Five delivered meals against the default four slots means one dish is
      // still pending when the last slot is logged. It must not vanish -- it
      // is already banked and the user can still log it.
      final dishes = [for (var i = 1; i <= 5; i++) _dish('Dish $i', i)];
      KuchniaQueueService.instance.offer(dishes);
      for (final dish in dishes.take(4)) {
        KuchniaQueueService.instance.markLogged(dish);
      }
      expect(KuchniaQueueService.remaining, 1);
      expect(KuchniaQueueService.next!.name, 'Dish 5');
    });

    test('dishes already logged today are not re-offered', () {
      KuchniaQueueService.instance.offer(
        [_dish('Pancakes', 1), _dish('Kaszotto', 2)],
        alreadyLogged: {'pancakes'},
      );
      expect(KuchniaQueueService.remaining, 1);
      expect(KuchniaQueueService.next!.name, 'Kaszotto');
    });

    test('clearing empties the queue', () {
      KuchniaQueueService.instance.offer([_dish('Pancakes', 1)]);
      KuchniaQueueService.instance.clear();
      expect(KuchniaQueueService.remaining, 0);
    });
  });

  group('the refresh guard', () {
    test('a day is unfetched until it is recorded', () async {
      expect(KuchniaQueueService.instance.alreadyFetched(today), isFalse);
      await KuchniaQueueService.instance.recordFetched(today);
      expect(KuchniaQueueService.instance.alreadyFetched(today), isTrue);
    });

    test('the marker is per day, not a flag', () async {
      await KuchniaQueueService.instance.recordFetched(today);
      expect(
        KuchniaQueueService.instance.alreadyFetched(DateTime(2026, 8, 24)),
        isFalse,
        reason: 'tomorrow has its own delivery; the marker is one ISO date',
      );
    });

    test('the marker survives a reload', () async {
      await KuchniaQueueService.instance.recordFetched(today);
      KuchniaQueueService.resetForTesting();
      await KuchniaQueueService.initForTesting(store);
      expect(KuchniaQueueService.instance.alreadyFetched(today), isTrue);
    });

    test('refreshOnce skips the walk once the day is recorded', () async {
      // The guard's whole job: the log-flow trigger fires after every meal,
      // and each unguarded refresh is a login plus three requests.
      await KuchniaQueueService.instance.recordFetched(today);
      final result = await KuchniaQueueService.refreshOnce(today);
      expect(
        result.ok,
        isTrue,
        reason: 'an already-fetched day is "nothing new", not an error',
      );
      expect(result.dishes, isEmpty);
    });

    test('refreshOnce is a no-op before the service is initialised', () async {
      KuchniaQueueService.resetForTesting();
      final result = await KuchniaQueueService.refreshOnce(today);
      expect(result.ok, isTrue);
      expect(result.dishes, isEmpty);
    });
  });
}
