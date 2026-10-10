// The user-approved acceptance scenario for minute slots: editing the
// schedule must never un-log a meal already eaten, on this device or in the
// reminders it posts.

import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/services/due_slot_check.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:diet_guard_app/services/notification_backend_io.dart';
import 'package:diet_guard_app/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_notifications.dart';
import 'body_test_support.dart';

const _manual = Nutrition(
  kcal: 200,
  proteinG: 10,
  carbsG: 20,
  fatG: 5,
  grams: 100,
  source: 'manual',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    LogStorageService.resetForTesting(store: MemoryDocStore());
    await MealScheduleService.initForTesting(MemoryDocStore());
  });

  tearDown(() {
    LogStorageService.resetForTesting();
    MealScheduleService.resetForTesting();
    NotificationService.resetForTesting();
  });

  test('moving the first meal 07:00 -> 07:15 keeps both meals logged', () async {
    const before = MealSchedule(firstMinute: 420, lastMinute: 1140, count: 5);
    const after = MealSchedule(firstMinute: 435, lastMinute: 1140, count: 5);
    expect(before.slots(), [420, 600, 780, 960, 1140]);
    expect(after.slots(), [435, 615, 795, 960, 1140]);

    final schedule = MealScheduleService.instance;
    await schedule.recordChange(before);
    final today = DateTime.now();
    DateTime at(int hour) => DateTime(today.year, today.month, today.day, hour);
    // Logged at 07:00 and 10:00 under the old schedule, so recorded as the
    // slots slotForLog attributed them to then.
    final storage = LogStorageService.instance;
    for (final hour in [7, 10]) {
      await storage.logMeal(
        'meal',
        _manual,
        slotMinute: slotForLog(at(hour), MealScheduleService.current),
      );
    }
    expect(await storage.loggedSlotsToday(), {420, 600});

    await schedule.recordChange(after);

    // Nothing stored was rewritten; each entry now snaps to its nearest slot.
    final logged = await storage.loggedSlotsToday();
    expect(logged, {435, 615});
    expect(missingSlots(at(11), logged, MealScheduleService.current), isEmpty);

    final log = installFakeAndroidNotifications();
    NotificationService.resetForTesting(
      backend: LocalNotificationsBackend(FlutterLocalNotificationsPlugin()),
    );
    await checkAndNotify(now: at(11), pullWhenDue: false);
    expect(log.where((c) => c.method == 'show'), isEmpty);
  });
}
