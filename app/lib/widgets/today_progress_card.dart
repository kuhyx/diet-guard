/// Post-log feedback card for the log screen: what was just logged, plus
/// today's standing against the daily budget.
library;

import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/progress_motion.dart';
import 'package:flutter/material.dart';

/// Everything [TodayProgressCard] renders, computed by the caller.
///
/// A plain value object rather than a service lookup so the card stays a
/// pure function of its inputs -- the log screen already holds the freshly
/// written log when it builds one of these, so a second read would be both
/// redundant and a chance to race.
@immutable
class TodayProgress {
  /// Creates a [TodayProgress].
  const TodayProgress({
    required this.consumedKcal,
    required this.budgetKcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.adherenceStreak,
    this.loggedSlotMinute,
    this.loggedKcal,
    this.previousKcal,
    this.previousAdherenceStreak,
  });

  /// Today's total calories, including the meal just logged.
  final double consumedKcal;

  /// The budget in effect *today* (not the schedule -- the card is only ever
  /// about the current day).
  final int budgetKcal;

  /// Today's total protein, grams.
  final double proteinG;

  /// Today's total carbohydrate, grams.
  final double carbsG;

  /// Today's total fat, grams.
  final double fatG;

  /// Consecutive-day budget-adherence streak, as of today.
  final int adherenceStreak;

  /// Slot (minute of day) of the meal just logged; null hides the
  /// confirmation line.
  final int? loggedSlotMinute;

  /// Calories of the meal just logged, exactly as stored.
  final double? loggedKcal;

  /// Today's total before this meal; null means no count-up.
  final double? previousKcal;

  /// Streak before this meal; null means it equals [adherenceStreak].
  final int? previousAdherenceStreak;

  /// Calories still available today; negative once over budget.
  double get remainingKcal => budgetKcal - consumedKcal;

  /// Whether today's total has passed the budget.
  bool get isOverBudget => remainingKcal < 0;
}

/// Shows today's running budget position after a meal is logged.
///
/// It used to open with a `Logged "<meal>".` line, removed 2026-08-16: the
/// user had just typed that description, so it restated the input instead of
/// telling them anything. What remains is what they act on.
///
/// Replaces the old one-tap-reward prompt: the same slot in the log screen,
/// but showing information the user actually acts on instead of an
/// externally-configured URL. Deliberately has no protein *target* -- that
/// derives from body weight, which only the PC stores (see
/// `diet_guard/_budget.py`'s `protein_target_g`), so the card reports
/// protein consumed and leaves targets to the gate's dashboard.
class TodayProgressCard extends StatelessWidget {
  /// Creates a [TodayProgressCard].
  const TodayProgressCard({required this.progress, super.key});

  /// The values to display.
  final TodayProgress progress;

  static String _plural(int count) => count == 1 ? 'day' : 'days';

  static String _grams(double value) => '${value.round()}g';

  /// Whole numbers without decimals; fractions exactly, never rounded.
  static String _kcal(double value) =>
      value == value.truncateToDouble() ? '${value.toInt()}' : '$value';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final slot = progress.loggedSlotMinute;
    final logged = progress.loggedKcal;
    final from = progress.previousKcal ?? progress.consumedKcal;
    final streakFrom =
        progress.previousAdherenceStreak ?? progress.adherenceStreak;
    return ProgressEntrance(
      key: ObjectKey(progress),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          // Fill-only elevation: the shared design system forbids shadows in
          // dark UI, and mixing a border with a fill on the same surface.
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (slot != null && logged != null) ...[
              Text(
                '✓ ${slotLabel(slot)} · ${_kcal(logged)} kcal',
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(height: AppSpacing.xs),
            ],
            CountUp(from: from, to: progress.consumedKcal, builder: _kcalRow),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'P ${_grams(progress.proteinG)}  ·  '
              'C ${_grams(progress.carbsG)}  ·  '
              'F ${_grams(progress.fatG)}',
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(height: AppSpacing.xs),
            CountUp(
              from: streakFrom.toDouble(),
              to: progress.adherenceStreak.toDouble(),
              builder: (context, value) {
                final days = value.round();
                return Text(
                  'Adherence streak: $days ${_plural(days)}',
                  style: theme.textTheme.labelSmall,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// The `<consumed> / <budget>` and `N left`/`N over` row at [consumed].
  Widget _kcalRow(BuildContext context, double consumed) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final remaining = progress.budgetKcal - consumed;
    final over = remaining < 0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '${consumed.round()} / ${progress.budgetKcal}',
          style: theme.textTheme.titleMedium?.copyWith(
            color: over ? colors.error : colors.onSurface,
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text('kcal', style: theme.textTheme.labelSmall),
        const Spacer(),
        Text(
          '${remaining.abs().round()} ${over ? 'over' : 'left'}',
          style: theme.textTheme.labelMedium?.copyWith(
            color: over ? colors.error : colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
