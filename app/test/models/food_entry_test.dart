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
        'imagePath': '/tmp/photo.jpg',
      });
      expect(entry.id, 'abc-123');
      expect(entry.desc, 'label_food');
      expect(entry.kcal, 300.0);
      expect(entry.slot, 16);
      expect(entry.hmac, 'deadbeef');
      expect(entry.components, hasLength(1));
      expect(entry.components!.first.name, 'rice');
      expect(entry.deleted, isTrue);
      expect(entry.imagePath, '/tmp/photo.jpg');
    });

    test('defaults missing macro fields to 0 and source to manual', () {
      final entry = FoodEntry.fromJson(const {'desc': 'mystery food'});
      expect(entry.id, isNull);
      expect(entry.kcal, 0);
      expect(entry.proteinG, 0);
      expect(entry.source, 'manual');
      expect(entry.slot, isNull);
      expect(entry.deleted, isFalse);
      expect(entry.components, isNull);
    });
  });

  group('toLocalJson vs toSyncJson', () {
    test('toLocalJson includes imagePath; toSyncJson excludes it and hmac', () {
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
        imagePath: '/local/photo.jpg',
      );
      final local = entry.toLocalJson();
      final sync = entry.toSyncJson();
      expect(local['imagePath'], '/local/photo.jpg');
      expect(sync.containsKey('imagePath'), isFalse);
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

    test('copyWithImagePath only changes imagePath', () {
      final updated = base.copyWithImagePath('/new/path.jpg');
      expect(updated.imagePath, '/new/path.jpg');
      expect(updated.id, base.id);
      expect(updated.deleted, isFalse);
      expect(updated.components, base.components);
    });

    test('copyWithDeleted sets deleted true and preserves everything else', () {
      final tombstoned = base.copyWithDeleted();
      expect(tombstoned.deleted, isTrue);
      expect(tombstoned.id, base.id);
      expect(tombstoned.kcal, base.kcal);
      expect(tombstoned.components, base.components);
    });
  });
}
