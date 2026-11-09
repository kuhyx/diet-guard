/// Post-log feedback card for the log screen: what was just logged, plus
/// today's standing against the daily budget.
library;

import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/ui/macro_kind.dart';
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

  static String _grams(double value) => '${value.round()}g';

  /// Whole numbers without decimals; fractions exactly, never rounded.
  static String _kcal(double value) =>
      value == value.truncateToDouble() ? '${value.toInt()}' : '$value';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = theme.extension<AppStatusColors>() ?? AppStatusColors.dark;
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
              Row(
                children: [
                  Icon(
                    Icons.check_circle,
                    size: 16,
                    color: status.success,
                    semanticLabel: 'logged',
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(slotLabel(slot), style: theme.textTheme.labelMedium),
                  const SizedBox(width: AppSpacing.sm),
                  MacroFigure(kind: MacroKind.kcal, value: _kcal(logged)),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
            ],
            CountUp(from: from, to: progress.consumedKcal, builder: _kcalRow),
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                MacroFigure(
                  kind: MacroKind.protein,
                  value: _grams(progress.proteinG),
                ),
                const SizedBox(width: AppSpacing.md),
                MacroFigure(
                  kind: MacroKind.carbs,
                  value: _grams(progress.carbsG),
                ),
                const SizedBox(width: AppSpacing.md),
                MacroFigure(kind: MacroKind.fat, value: _grams(progress.fatG)),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            CountUp(
              from: streakFrom.toDouble(),
              to: progress.adherenceStreak.toDouble(),
              builder: (context, value) => Row(
                children: [
                  Icon(
                    Icons.local_fire_department,
                    size: 16,
                    color: status.warning,
                    semanticLabel: 'adherence streak',
                  ),
                  const SizedBox(width: 3),
                  Text('${value.round()}', style: theme.textTheme.labelMedium),
                ],
              ),
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
    final tint = over ? colors.error : colors.onSurface;
    // Bar fill = share of the budget used; it turns red AND the right-hand
    // glyph flips from a flag (room left) to a warning (over) past the budget.
    final used = progress.budgetKcal > 0
        ? (consumed / progress.budgetKcal).clamp(0.0, 1.0)
        : 1.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              MacroKind.kcal.icon,
              size: 18,
              color: MacroKind.kcal.color,
              semanticLabel: 'kcal',
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              '${consumed.round()} / ${progress.budgetKcal}',
              style: theme.textTheme.titleMedium?.copyWith(color: tint),
            ),
            const Spacer(),
            Icon(
              over ? Icons.warning_amber_rounded : Icons.flag_outlined,
              size: 16,
              color: over ? colors.error : colors.onSurfaceVariant,
              semanticLabel: over ? 'over budget' : 'left',
            ),
            const SizedBox(width: 3),
            Text(
              '${remaining.abs().round()}',
              style: theme.textTheme.labelMedium?.copyWith(color: tint),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        LinearProgressIndicator(
          value: used,
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
          color: over ? colors.error : colors.primary,
          backgroundColor: colors.surfaceContainerHighest,
        ),
      ],
    );
  }
}
