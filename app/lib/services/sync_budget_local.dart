/// Budget record local side, shared by the sync tick and the data import.
library;

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:diet_guard_app/services/sync_merge.dart';
import 'package:diet_guard_app/services/sync_merge_schedule.dart';

/// This device's budget record; schedule-only edits stamp it at the epoch.
Log localBudgetLog() {
  final updatedAt = AppSettingsService.dailyKcalGoalUpdatedAt;
  final scheduleEntries = MealScheduleService.history.entries;
  final recordStamp =
      updatedAt ??
      (scheduleEntries.isEmpty ? null : MealScheduleService.updatedAt);
  final localRecord = recordStamp == null
      ? null
      : <String, dynamic>{
          'v': 2,
          'b': AppSettingsService.dailyKcalGoal,
          't': (updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
              .toIso8601String(),
        };
  return budgetToLog(
    localRecord,
    BudgetHistoryService.schedule.entries,
    scheduleEntries,
  );
}

/// Applies a merged budget [Log]: history, schedule, then the scalar.
Future<void> applyBudgetLog(Log merged) async {
  await BudgetHistoryService.instance.applyMerged(logToHistory(merged));
  if (MealScheduleService.isInitialized) {
    await MealScheduleService.instance.applyMerged(
      logToScheduleHistory(merged),
      updatedAt: MealScheduleService.updatedAt,
    );
  }
  final budget = logToBudget(merged);
  final mergedKcal = budget?['b'];
  if (budget == null || mergedKcal is! int) return;
  await AppSettingsService.instance.applySyncedBudget(
    mergedKcal,
    updatedAt: DateTime.tryParse(budget['t'] as String? ?? ''),
  );
}
