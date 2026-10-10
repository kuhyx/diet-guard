/// The fill rule and the batch write behind "Fill all with catering".
///
/// Mirrors the PC's `fill_plan` / `log_dishes`. The assertions that matter
/// count what *lands*: a rule that drops an occupied slot but double-writes
/// an empty one still shows "the dish was offered".
library;

import 'package:diet_guard_app/services/kuchnia_fill.dart';
import 'package:diet_guard_app/services/kuchnia_spread.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'kuchnia_fill_support.dart';

List<String> _names(List<SlottedDish> plan) => [
  for (final item in plan) '${item.dish.name}@${item.slot}',
];

void main() {
  tearDown(LogStorageService.resetForTesting);

  group('fillPlan', () {
    test('an empty day keeps every dish', () {
      final slotted = assignSlots(dishes(4), defaultSlots);
      expect(_names(fillPlan(slotted, {})), [
        'D1@8',
        'D2@12',
        'D3@16',
        'D4@20',
      ]);
    });

    test('an occupied slot is skipped, the others stay', () {
      final slotted = assignSlots(dishes(4), defaultSlots);
      expect(_names(fillPlan(slotted, {12})), ['D1@8', 'D3@16', 'D4@20']);
    });

    test('5 dishes on 4 slots: both dishes of one empty slot stay', () {
      final slotted = assignSlots(dishes(5), defaultSlots);
      // The spread doubles the first slot; occupancy is read once, so the
      // first dish must not shadow the second.
      expect(_names(slotted).take(2), ['D1@8', 'D2@8']);
      expect(_names(fillPlan(slotted, {})), hasLength(5));
      expect(_names(fillPlan(slotted, {16})), [
        'D1@8',
        'D2@8',
        'D3@12',
        'D5@20',
      ]);
    });

    test('an occupied doubled slot drops both of its dishes', () {
      final slotted = assignSlots(dishes(5), defaultSlots);
      expect(_names(fillPlan(slotted, {8})), ['D3@12', 'D4@16', 'D5@20']);
    });

    test('a full day yields an empty plan', () {
      final slotted = assignSlots(dishes(4), defaultSlots);
      expect(fillPlan(slotted, {8, 12, 16, 20}), isEmpty);
    });
  });

  group('dishNutrition', () {
    test('is the whole portion, tagged as kuchnia wikinga', () {
      final nutrition = dishNutrition(dish('D2', 2, grams: 312.4));
      expect(nutrition.source, 'kuchnia wikinga');
      expect(nutrition.source, kuchniaSource);
      expect(nutrition.grams, 312.4);
      expect(nutrition.kcal, 200);
      expect(nutrition.proteinG, 20);
      expect(nutrition.carbsG, 20.5);
      expect(nutrition.fatG, 5);
    });
  });

  group('logDishes', () {
    test(
      'writes through storage with source and whole-portion grams',
      () async {
        final storage = freshStorage();
        final chosen = [
          at(dish('D1', 1, grams: 250), 8),
          at(dish('D3', 3), 16),
        ];

        final written = await logDishes(chosen, storage: storage);

        expect(_names(written), ['D1@8', 'D3@16']);
        final entries = await storage.todayEntries();
        expect(entries.map((e) => e.desc), ['D1', 'D3']);
        expect(entries.map((e) => e.slot), [8, 16]);
        expect(entries.map((e) => e.source), everyElement('kuchnia wikinga'));
        expect(entries.map((e) => e.grams), [250, 300]);
        expect(entries.map((e) => e.kcal), [100, 300]);
      },
    );

    test('skips a dish already logged in that slot', () async {
      final storage = freshStorage();
      await storage.logMeal('  d1 ', dishNutrition(dish('D1', 1)), slot: 8);

      final written = await logDishes([
        at(dish('D1', 1), 8),
        at(dish('D2', 2), 12),
      ], storage: storage);

      // Case and surrounding whitespace do not make it a different meal.
      expect(_names(written), ['D2@12']);
      expect(await storage.todayEntries(), hasLength(2));
    });

    test('an intra-batch duplicate lands once', () async {
      final storage = freshStorage();
      final twin = dish('Twin', 1);

      final written = await logDishes([
        at(twin, 8),
        at(twin, 8),
      ], storage: storage);

      expect(_names(written), ['Twin@8']);
      expect(await loggedToday(storage), ['Twin@8']);
    });

    test('the same dish in a different slot is not a duplicate', () async {
      final storage = freshStorage();
      await storage.logMeal('D1', dishNutrition(dish('D1', 1)), slot: 8);

      final written = await logDishes([
        at(dish('D1', 1), 12),
      ], storage: storage);

      expect(_names(written), ['D1@12']);
      expect(await loggedToday(storage), ['D1@8', 'D1@12']);
    });
  });

  group('planSummary', () {
    test('lists slot, dish and the kcal total', () {
      final plan = [at(dish('D1', 1), 8), at(dish('D2', 2), 12)];
      expect(
        planSummary(plan),
        'Will log 2 (300 kcal): 08:00 D1, 12:00 D2 — tap Confirm.',
      );
    });
  });
}
