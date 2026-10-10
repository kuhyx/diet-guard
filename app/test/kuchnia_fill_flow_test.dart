/// The two-tap state machine behind "Fill all with catering".
///
/// The guarantee under test is that *no write happens on the first tap* and
/// that the confirm re-reads the world: occupancy at write time, and the
/// calendar day. Each test asserts the log's contents, not a return value.
library;

import 'dart:async';

import 'package:diet_guard_app/services/kuchnia_fill.dart';
import 'package:diet_guard_app/services/kuchnia_fill_flow.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'kuchnia_fill_support.dart';

/// Counts and records fetches; the result is swappable per test.
class _Fetcher {
  _Fetcher(this.result);

  KuchniaRefresh result;
  final List<DateTime> days = [];
  Completer<void>? gate;

  Future<KuchniaRefresh> call(DateTime day) async {
    days.add(day);
    if (gate != null) await gate!.future;
    return result;
  }
}

void main() {
  late LogStorageService storage;
  late _Fetcher fetcher;
  late DateTime clock;
  late Set<int> occupied;
  late int occupancyReads;
  Completer<void>? occupancyGate;
  late FillAllFlow flow;

  setUp(() {
    storage = freshStorage();
    fetcher = _Fetcher(KuchniaRefresh(dishes: dishes(4)));
    clock = DateTime(2026, 8, 23, 10);
    occupied = {};
    occupancyReads = 0;
    occupancyGate = null;
    flow = FillAllFlow(
      fetch: fetcher.call,
      now: () => clock,
      slots: () => defaultSlots,
      occupiedSlots: () async {
        occupancyReads++;
        if (occupancyGate != null) await occupancyGate!.future;
        return {...occupied};
      },
      storage: storage,
    );
  });

  tearDown(LogStorageService.resetForTesting);

  test('the first tap proposes and writes nothing', () async {
    final outcome = await flow.tap();

    expect(outcome!.written, isEmpty);
    expect(outcome.message, startsWith('Will log 4'));
    expect(flow.armedCount, 4);
    expect(await storage.todayEntries(), isEmpty);
    expect(fetcher.days, [DateTime(2026, 8, 23)]);
  });

  test('the second tap logs the plan with the catering source', () async {
    await flow.tap();
    final outcome = await flow.tap();

    expect(outcome!.message, 'Logged 4 catering dishes.');
    expect(await loggedToday(storage), ['D1@8', 'D2@12', 'D3@16', 'D4@20']);
    expect(
      (await storage.todayEntries()).map((e) => e.source),
      everyElement(kuchniaSource),
    );
    expect(flow.armedCount, 0);
    expect(fetcher.days, hasLength(1), reason: 'confirm must not refetch');
  });

  test(
    'confirm re-checks occupancy: a meal logged between taps stays',
    () async {
      await flow.tap();
      expect(flow.armedCount, 4);
      // Logged on the PC (or here) after the proposal was shown.
      await storage.logMeal(
        'my own lunch',
        dishNutrition(dish('x', 1)),
        slot: 12,
      );
      occupied = {12};

      final outcome = await flow.tap();

      expect(outcome!.message, 'Logged 3 catering dishes.');
      expect(await loggedToday(storage), [
        'my own lunch@12',
        'D1@8',
        'D3@16',
        'D4@20',
      ]);
      expect(occupancyReads, 2, reason: 'once to propose, once to confirm');
    },
  );

  test('a confirm into a now-full day writes nothing', () async {
    await flow.tap();
    occupied = {8, 12, 16, 20};

    final outcome = await flow.tap();

    expect(outcome!.message, nothingToFillMessage);
    expect(outcome.written, isEmpty);
    expect(await storage.todayEntries(), isEmpty);
    expect(flow.armedCount, 0);
  });

  test(
    '5 dishes on 4 slots: both dishes of an empty slot are logged',
    () async {
      fetcher.result = KuchniaRefresh(dishes: dishes(5));
      await flow.tap();
      await flow.tap();

      expect(await loggedToday(storage), [
        'D1@8',
        'D2@8',
        'D3@12',
        'D4@16',
        'D5@20',
      ]);
    },
  );

  group('midnight', () {
    test('a plan from yesterday is refetched, not confirmed', () async {
      clock = DateTime(2026, 8, 23, 23, 59);
      await flow.tap();
      expect(flow.armedCount, 4);

      clock = DateTime(2026, 8, 24, 0, 1);
      final outcome = await flow.tap();

      expect(fetcher.days, [DateTime(2026, 8, 23), DateTime(2026, 8, 24)]);
      expect(outcome!.written, isEmpty);
      expect(outcome.message, startsWith('Will log 4'));
      expect(await storage.todayEntries(), isEmpty);
      expect(flow.armedCount, 4, reason: 're-armed for the new day');
    });

    test('the day is pinned at tap time, not when the fetch lands', () async {
      clock = DateTime(2026, 8, 23, 23, 59);
      fetcher.gate = Completer<void>();
      final pending = flow.tap();
      clock = DateTime(2026, 8, 24, 0, 1);
      fetcher.gate!.complete();
      await pending;

      // That menu was fetched for the 23rd: a tap on the 24th must refetch
      // rather than confirm it.
      fetcher.gate = null;
      final outcome = await flow.tap();

      expect(fetcher.days, [DateTime(2026, 8, 23), DateTime(2026, 8, 24)]);
      expect(outcome!.written, isEmpty);
      expect(await storage.todayEntries(), isEmpty);
    });
  });

  group('nothing to arm', () {
    test('a fetch error surfaces its reason', () async {
      fetcher.result = const KuchniaRefresh(reason: 'Login failed (401).');
      final outcome = await flow.tap();

      expect(outcome!.message, 'Login failed (401).');
      expect(flow.armedCount, 0);
    });

    test('no delivery says so', () async {
      fetcher.result = const KuchniaRefresh();
      final outcome = await flow.tap();

      expect(outcome!.message, 'No catering delivery today.');
      expect(flow.armedCount, 0);
    });

    test('all slots full arms nothing', () async {
      occupied = {8, 12, 16, 20};
      final outcome = await flow.tap();

      expect(outcome!.message, nothingToFillMessage);
      expect(flow.armedCount, 0);
      // The next tap fetches again instead of "confirming" an empty plan.
      await flow.tap();
      expect(fetcher.days, hasLength(2));
      expect(await storage.todayEntries(), isEmpty);
    });
  });

  group('busy', () {
    test('a tap while the fetch is pending is ignored', () async {
      fetcher.gate = Completer<void>();
      final first = flow.tap();
      expect(flow.busy, isTrue);

      expect(await flow.tap(), isNull);
      expect(fetcher.days, hasLength(1));

      fetcher.gate!.complete();
      final outcome = await first;
      expect(flow.busy, isFalse);
      expect(outcome!.message, startsWith('Will log 4'));
      expect(await storage.todayEntries(), isEmpty);
    });

    test('a second tap during the confirm cannot log twice', () async {
      await flow.tap();
      occupancyGate = Completer<void>();
      final confirm = flow.tap();
      expect(flow.busy, isTrue);

      expect(await flow.tap(), isNull);

      occupancyGate!.complete();
      await confirm;
      expect(flow.busy, isFalse);
      expect(await loggedToday(storage), hasLength(4));
    });
  });

  test('cancel disarms; the next tap fetches again', () async {
    await flow.tap();
    flow.cancel();

    expect(flow.armedCount, 0);
    final outcome = await flow.tap();

    expect(fetcher.days, hasLength(2));
    expect(outcome!.written, isEmpty);
    expect(await storage.todayEntries(), isEmpty);
  });
}
