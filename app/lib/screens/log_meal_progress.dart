import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/day_status_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/widgets/today_progress_card.dart';
import 'package:flutter/widgets.dart';

/// Reads a macro field as a number, treating blank or unparsable as zero.
double parseMacroField(TextEditingController controller) =>
    double.tryParse(controller.text.trim()) ?? 0;

/// Summarises today from the log just written.
///
/// Takes the already-read [log] rather than re-reading, so the card can
/// never disagree with the write that produced it.
TodayProgress buildTodayProgress(DayLog log) {
  final budget = AppSettingsService.dailyKcalGoal;
  final today = localDateKey(DateTime.now());
  final entries = (log[today] ?? const <FoodEntry>[])
      .where((entry) => !entry.deleted)
      .toList();
  final macros = sumMacros(entries);
  return TodayProgress(
    consumedKcal: sumKcal(entries),
    budgetKcal: budget,
    proteinG: macros.proteinG,
    carbsG: macros.carbsG,
    fatG: macros.fatG,
    adherenceStreak: adherenceStreak(
      statusMap(log, schedule: BudgetHistoryService.schedule),
    ),
  );
}
