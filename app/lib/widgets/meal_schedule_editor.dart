/// The meal-schedule editor: first meal, last meal, how many meals, and a
/// live preview of the checkpoint times they derive.
library;

import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/meal_time_dropdown.dart';
import 'package:flutter/material.dart';

/// Latest minute the *grid* offers for the first meal: 23:30, leaving one
/// grid step for a grid-aligned last meal. "Custom…" can go later, up to the
/// 23:44 that [MealSchedule.normalized] allows.
const int _firstGridMax = kMinutesPerDay - 2 * kSlotGridMinutes;

/// Latest first-meal minute [MealSchedule.normalized] keeps: one grid step
/// before the end of the day.
const int _firstMax = kMinutesPerDay - 1 - kSlotGridMinutes;

/// Edits a [MealSchedule], reporting every change through [onChanged].
///
/// Stateless: the owner holds the schedule and persists it. Every offered
/// value is already legal, so `normalized()` in the owner is the defence
/// against corrupt synced data rather than the input contract.
class MealScheduleEditor extends StatelessWidget {
  /// Creates a [MealScheduleEditor].
  const MealScheduleEditor({
    required this.schedule,
    required this.onChanged,
    super.key,
  });

  /// The schedule being shown.
  final MealSchedule schedule;

  /// Called with the edited (not yet normalised) schedule.
  final ValueChanged<MealSchedule> onChanged;

  /// The meal counts selectable for the current window.
  ///
  /// Capped at the number of grid-spaced checkpoints the window holds, so the
  /// dropdown can never offer a count that would round two meals onto the
  /// same quarter hour -- the same capacity rule `normalized` enforces.
  List<int> get selectableCounts {
    final span = schedule.lastMinute - schedule.firstMinute;
    final capacity = span ~/ kSlotGridMinutes + 1;
    final maxCount = capacity < kMaxMealCount ? capacity : kMaxMealCount;
    return [for (var n = kMinMealCount; n <= maxCount; n++) n];
  }

  MealSchedule _with({int? first, int? last, int? count}) => MealSchedule(
    firstMinute: first ?? schedule.firstMinute,
    lastMinute: last ?? schedule.lastMinute,
    count: count ?? schedule.count,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counts = selectableCounts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Meal times', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Checkpoints are spread evenly between your first and last meal.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        MealTimeDropdown(
          label: 'First meal',
          value: schedule.firstMinute,
          minMinute: 0,
          maxMinute: _firstMax,
          gridMaxMinute: _firstGridMax,
          onChanged: (minute) => onChanged(_with(first: minute)),
        ),
        const SizedBox(height: 12),
        MealTimeDropdown(
          label: 'Last meal',
          value: schedule.lastMinute,
          // At least one grid step after the first meal: the shortest window
          // that still holds two distinct checkpoints.
          minMinute: schedule.firstMinute + kSlotGridMinutes,
          maxMinute: kMinutesPerDay - 1,
          onChanged: (minute) => onChanged(_with(last: minute)),
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppWidth.field),
          child: InputDecorator(
            decoration: const InputDecoration(labelText: 'Meals per day'),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: counts.contains(schedule.count)
                    ? schedule.count
                    : counts.last,
                isDense: true,
                isExpanded: true,
                items: [
                  for (final count in counts)
                    DropdownMenuItem(value: count, child: Text('$count')),
                ],
                onChanged: (count) =>
                    count == null ? null : onChanged(_with(count: count)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          schedule.slots().map(slotLabel).join('  ·  '),
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }
}
