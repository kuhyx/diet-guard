import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/screens/log_meal_progress.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:flutter_test/flutter_test.dart';

FoodEntry _entry({int? slotMinute}) => FoodEntry(
  time: DateTime.now().toIso8601String(),
  desc: 'oats',
  grams: 100,
  kcal: 300,
  proteinG: 10,
  carbsG: 50,
  fatG: 5,
  source: 'manual',
  id: 'e1',
  slotMinute: slotMinute,
);

void main() {
  test('the logged slot is the stamped one when the entry carries it', () {
    final entry = _entry(slotMinute: 480);
    final progress = buildTodayProgress({
      localDateKey(DateTime.now()): [entry],
    }, logged: entry);
    expect(progress.loggedSlotMinute, 480);
  });

  test('an unstamped entry falls back to the slot its time maps to', () {
    final entry = _entry();
    final progress = buildTodayProgress({
      localDateKey(DateTime.now()): [entry],
    }, logged: entry);
    expect(
      progress.loggedSlotMinute,
      slotForLog(DateTime.parse(entry.time), MealScheduleService.current),
    );
  });
}
