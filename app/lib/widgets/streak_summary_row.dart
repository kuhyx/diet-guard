/// Streak and year-to-date tally summary row for the History screen.
library;

import 'package:diet_guard_app/models/day_status.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// Displays the logging streak, adherence streak, and year-to-date tally.
///
/// Mirrors `_calendar_view.py`'s `streaks_text`/`ytd_text` data, as glyphs and
/// numerals: pencil + N (logging streak), flame + N (adherence streak),
/// calendar-check + X/Y (days logged of days elapsed), medal + Z (days within
/// budget).
class StreakSummaryRow extends StatelessWidget {
  /// Creates a [StreakSummaryRow].
  const StreakSummaryRow({
    required this.loggingStreak,
    required this.adherenceStreak,
    required this.tally,
    super.key,
  });

  /// Consecutive-day logging streak.
  final int loggingStreak;

  /// Consecutive-day budget-adherence streak.
  final int adherenceStreak;

  /// This year's logged/elapsed/adherent day counts.
  final YtdTally tally;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = theme.extension<AppStatusColors>() ?? AppStatusColors.dark;
    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: AppSpacing.lg,
          children: [
            _Figure(
              icon: Icons.edit_note,
              color: theme.colorScheme.primary,
              semanticLabel: 'Logging streak',
              value: '$loggingStreak',
              style: theme.textTheme.titleSmall,
            ),
            _Figure(
              icon: Icons.local_fire_department,
              color: status.warning,
              semanticLabel: 'Adherence streak',
              value: '$adherenceStreak',
              style: theme.textTheme.titleSmall,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: AppSpacing.lg,
          children: [
            _Figure(
              icon: Icons.event_available,
              color: theme.colorScheme.onSurfaceVariant,
              semanticLabel: 'Days logged this year',
              value: '${tally.loggedDays}/${tally.elapsedDays}',
              style: theme.textTheme.bodySmall,
            ),
            _Figure(
              icon: Icons.verified,
              color: status.success,
              semanticLabel: 'Days within budget',
              value: '${tally.adherentDays}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.icon,
    required this.color,
    required this.semanticLabel,
    required this.value,
    required this.style,
  });

  final IconData icon;
  final Color color;
  final String semanticLabel;
  final String value;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: color, size: 18, semanticLabel: semanticLabel),
      const SizedBox(width: 4),
      Text(value, style: style),
    ],
  );
}
