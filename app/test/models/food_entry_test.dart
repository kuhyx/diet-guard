import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/meal_component.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FoodEntry.fromJson', () {
    test('parses a fully-populated entry', () {
      final entry = FoodEntry.fromJson({
        'id': 'abc-123',
        'time': '2026-06-22T17:41:17+02:00',
        'desc': 'label_food',
        'grams': 150.0,
        'kcal': 300.0,
        'protein_g': 15.0,
        'carbs_g': 30.0,
        'fat_g': 7.5,
        'source': 'manual',
        'slot': 16,
        'hmac': 'deadbeef',
        'components': [
          {
            'name': 'rice',
            'kcal': 200.0,
            'protein_g': 4.0,
            'carbs_g': 44.0,
            'fat_g': 1.0,
            'grams': 150.0,
          },
        ],
        'deleted': true,
      });
      expect(entry.id, 'abc-123');
      expect(entry.desc, 'label_food');
      expect(entry.kcal, 300.0);
      expect(entry.slotMinute, 960);
      expect(entry.hmac, 'deadbeef');
      expect(entry.components, hasLength(1));
      expect(entry.components!.first.name, 'rice');
      expect(entry.deleted, isTrue);
    });

    test('defaults missing macro fields to 0 and source to manual', () {
      final entry = FoodEntry.fromJson(const {'desc': 'mystery food'});
      expect(entry.id, isNull);
      expect(entry.kcal, 0);
      expect(entry.proteinG, 0);
      expect(entry.source, 'manual');
      expect(entry.slotMinute, isNull);
      expect(entry.deleted, isFalse);
      expect(entry.components, isNull);
    });
  });

  group('toLocalJson vs toSyncJson', () {
    test('toLocalJson matches toSyncJson; both exclude hmac', () {
      const entry = FoodEntry(
        id: 'id-1',
        time: '2026-06-22T08:00:00+02:00',
        desc: 'toast',
        grams: 50,
        kcal: 120,
        proteinG: 3,
        carbsG: 20,
        fatG: 2,
        source: 'manual',
        hmac: 'sig',
      );
      final local = entry.toLocalJson();
      final sync = entry.toSyncJson();
      expect(local, sync);
      expect(sync.containsKey('hmac'), isFalse);
      expect(sync['desc'], 'toast');
    });

    test('omits optional fields entirely when unset', () {
      const entry = FoodEntry(
        time: '2026-06-22T08:00:00+02:00',
        desc: 'toast',
        grams: 50,
        kcal: 120,
        proteinG: 3,
        carbsG: 20,
        fatG: 2,
        source: 'manual',
      );
      final sync = entry.toSyncJson();
      expect(sync.containsKey('id'), isFalse);
      expect(sync.containsKey('slot'), isFalse);
      expect(sync.containsKey('components'), isFalse);
      expect(sync.containsKey('deleted'), isFalse);
    });

    test('includes deleted: true only when tombstoned', () {
      const entry = FoodEntry(
        time: '2026-06-22T08:00:00+02:00',
        desc: 'toast',
        grams: 50,
        kcal: 120,
        proteinG: 3,
        carbsG: 20,
        fatG: 2,
        source: 'manual',
        deleted: true,
      );
      expect(entry.toSyncJson()['deleted'], isTrue);
    });
  });

  group('copyWithImagePath / copyWithDeleted', () {
    const base = FoodEntry(
      id: 'id-1',
      time: '2026-06-22T08:00:00+02:00',
      desc: 'toast',
      grams: 50,
      kcal: 120,
      proteinG: 3,
      carbsG: 20,
      fatG: 2,
      source: 'manual',
      components: [
        MealComponent(
          name: 'bread',
          kcal: 120,
          proteinG: 3,
          carbsG: 20,
          fatG: 2,
          grams: 50,
        ),
      ],
    );

    test('copyWithDeleted sets deleted true and preserves everything else', () {
      final tombstoned = base.copyWithDeleted();
      expect(tombstoned.deleted, isTrue);
      expect(tombstoned.id, base.id);
      expect(tombstoned.kcal, base.kcal);
      expect(tombstoned.components, base.components);
    });
  });

  group('slot minute round trip', () {
    Map<String, Object?> entry(Map<String, Object?> slot) => {
      'id': 'id-1',
      'time': '2026-06-22T07:15:00+02:00',
      'desc': 'toast',
      'grams': 50.0,
      'kcal': 120.0,
      'protein_g': 3.0,
      'carbs_g': 20.0,
      'fat_g': 2.0,
      'source': 'manual',
      ...slot,
    };

    test('a PC entry with slot_min survives a phone round trip', () {
      // The regression this guards: keeping only the hour made every phone
      // edit or tombstone republish a stripped copy of the PC's entry.
      final raw = entry({'slot': 7, 'slot_min': 435});
      final parsed = FoodEntry.fromJson(raw);
      expect(parsed.slotMinute, 435);
      expect(parsed.toSyncJson(), raw);
      expect(parsed.copyWithDeleted().slotMinute, 435);
      expect(parsed.copyWithDeleted().toSyncJson()['slot_min'], 435);
    });

    test('a legacy whole-hour entry stays byte-identical', () {
      final raw = entry({'slot': 8});
      final parsed = FoodEntry.fromJson(raw);
      expect(parsed.slotMinute, 480);
      expect(parsed.toSyncJson(), raw);
      expect(parsed.toSyncJson().containsKey('slot_min'), isFalse);
    });

    test('an out-of-range peer slot is echoed, never thrown on', () {
      // slotFields throws outside the day; writeLog encodes every entry, so a
      // throw here would block all logging behind one bad synced entry.
      expect(FoodEntry.fromJson(entry({'slot': 24})).toSyncJson()['slot'], 24);
      final late = FoodEntry.fromJson(entry({'slot_min': 1510})).toSyncJson();
      expect(late['slot'], 25);
      expect(late['slot_min'], 1510);
      final negative = FoodEntry.fromJson(entry({'slot': -1})).toSyncJson();
      expect(negative.containsKey('slot'), isFalse);
      expect(negative['slot_min'], -60);
    });
  });
}
