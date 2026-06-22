import 'package:diet_guard_app/models/nutrition.dart';
import 'package:flutter_test/flutter_test.dart';

Nutrition _ref({
  double kcal = 200,
  double proteinG = 10,
  double carbsG = 20,
  double fatG = 5,
  double grams = 100,
  String source = 'manual',
}) => Nutrition(
  kcal: kcal,
  proteinG: proteinG,
  carbsG: carbsG,
  fatG: fatG,
  grams: grams,
  source: source,
);

void main() {
  group('scaleNutrition', () {
    test('scales every macro proportionally to the new weight', () {
      final result = scaleNutrition(_ref(), 150);
      expect(result.kcal, 300);
      expect(result.proteinG, 15);
      expect(result.carbsG, 30);
      expect(result.fatG, 7.5);
      expect(result.grams, 150);
      expect(result.source, 'manual');
    });

    test('is a no-op when the new weight equals the basis weight', () {
      final result = scaleNutrition(_ref(), 100);
      expect(result.kcal, 200);
      expect(result.proteinG, 10);
      expect(result.grams, 100);
    });

    test('keeps macros unchanged when the basis weight is unknown', () {
      final result = scaleNutrition(_ref(grams: 0), 150);
      expect(result.kcal, 200);
      expect(result.grams, 150);
    });

    test('keeps macros and basis weight when the new weight is unknown', () {
      final result = scaleNutrition(_ref(), 0);
      expect(result.kcal, 200);
      expect(result.grams, 100);
    });

    test('keeps basis weight when both weights are unknown', () {
      final result = scaleNutrition(_ref(grams: 0), 0);
      expect(result.grams, 0);
    });
  });

  group('nutritionForPortion', () {
    test('scales label macros to the amount actually eaten', () {
      final result = nutritionForPortion(
        kcal: 200,
        proteinG: 10,
        carbsG: 20,
        fatG: 5,
        perGrams: 100,
        ateGrams: 150,
        source: 'manual',
      );
      expect(result.kcal, 300);
      expect(result.proteinG, 15);
      expect(result.carbsG, 30);
      expect(result.fatG, 7.5);
      expect(result.grams, 150);
    });

    test(
      'treats typed macros as totals when per-grams is left blank '
      '(back-compatible with the original single-grams-field behaviour)',
      () {
        final result = nutritionForPortion(
          kcal: 250,
          proteinG: 12,
          carbsG: 30,
          fatG: 8,
          perGrams: 0,
          ateGrams: 150,
          source: 'manual',
        );
        expect(result.kcal, 250);
        expect(result.proteinG, 12);
        expect(result.grams, 150);
      },
    );

    test(
      'assumes the eaten amount equals per-grams when amount eaten is '
      'left blank',
      () {
        final result = nutritionForPortion(
          kcal: 200,
          proteinG: 10,
          carbsG: 20,
          fatG: 5,
          perGrams: 100,
          ateGrams: 0,
          source: 'manual',
        );
        expect(result.kcal, 200);
        expect(result.grams, 100);
      },
    );

    test('keeps macros as typed when both grams fields are blank', () {
      final result = nutritionForPortion(
        kcal: 90,
        proteinG: 3,
        carbsG: 4,
        fatG: 1,
        perGrams: 0,
        ateGrams: 0,
        source: 'manual',
      );
      expect(result.kcal, 90);
      expect(result.grams, 0);
    });

    test('stamps the requested source', () {
      final result = nutritionForPortion(
        kcal: 100,
        proteinG: 1,
        carbsG: 1,
        fatG: 1,
        perGrams: 100,
        ateGrams: 100,
        source: 'food bank',
      );
      expect(result.source, 'food bank');
    });
  });
}
