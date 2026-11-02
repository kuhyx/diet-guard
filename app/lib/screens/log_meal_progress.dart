import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/day_status_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:diet_guard_app/widgets/today_progress_card.dart';
import 'package:flutter/widgets.dart';

/// Reads a macro field as a number, treating blank or unparsable as zero.
double parseMacroField(TextEditingController controller) =>
    double.tryParse(controller.text.trim()) ?? 0;

/// Summarises today from the log just written.
///
/// Takes the already-read [log] rather than re-reading, so the card can
/// never disagree with the write that produced it. [logged] is that write:
/// the card counts up from the totals without it.
TodayProgress buildTodayProgress(DayLog log, {FoodEntry? logged}) {
  final budget = AppSettingsService.dailyKcalGoal;
  final today = localDateKey(DateTime.now());
  final entries = _live(log[today]);
  final before = logged == null ? log : _without(log, logged.id);
  final macros = sumMacros(entries);
  return TodayProgress(
    consumedKcal: sumKcal(entries),
    budgetKcal: budget,
    proteinG: macros.proteinG,
    carbsG: macros.carbsG,
    fatG: macros.fatG,
    adherenceStreak: _streak(log),
    loggedSlotMinute: logged == null ? null : _slotOf(logged),
    loggedKcal: logged?.kcal,
    previousKcal: logged == null ? null : sumKcal(_live(before[today])),
    previousAdherenceStreak: logged == null ? null : _streak(before),
  );
}

int _slotOf(FoodEntry entry) =>
    entry.slotMinute ??
    slotForLog(DateTime.parse(entry.time), MealScheduleService.current);

List<FoodEntry> _live(List<FoodEntry>? entries) =>
    (entries ?? const <FoodEntry>[]).where((entry) => !entry.deleted).toList();

int _streak(DayLog log) =>
    adherenceStreak(statusMap(log, schedule: BudgetHistoryService.schedule));

DayLog _without(DayLog log, String? id) => {
  for (final MapEntry(:key, :value) in log.entries)
    key: [
      for (final entry in value)
        if (entry.id != id) entry,
    ],
};
