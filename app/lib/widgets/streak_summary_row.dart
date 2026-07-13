/// Streak and year-to-date tally summary row for the History screen.
library;

import 'package:diet_guard_app/models/day_status.dart';
import 'package:flutter/material.dart';

/// Displays the logging streak, adherence streak, and year-to-date tally.
///
/// Mirrors `_calendar_view.py`'s `streaks_text`/`ytd_text` formatting:
/// "Logging streak: N day(s) · Adherence streak: N day(s)" and
/// "This year: logged X/Y days · Z within budget".
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

  static String _plural(int count) => count == 1 ? 'day' : 'days';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(
          'Logging streak: $loggingStreak ${_plural(loggingStreak)}  ·  '
          'Adherence streak: $adherenceStreak ${_plural(adherenceStreak)}',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          'This year: logged ${tally.loggedDays}/${tally.elapsedDays} days  ·  '
          '${tally.adherentDays} within budget',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
