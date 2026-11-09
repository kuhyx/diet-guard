/// Weekly/monthly average-intake summary row for the History screen.
library;

import 'package:diet_guard_app/models/period_average.dart';
import 'package:diet_guard_app/ui/cues.dart';
import 'package:diet_guard_app/ui/macro_kind.dart';
import 'package:flutter/material.dart';

/// Displays this week's and this month's average kcal/day and their bands.
///
/// Mirrors `_calendar_view.py`'s `averages_text`, minus the words: each period
/// is a calendar glyph, the average as a number, and the band as a tinted
/// icon (check = under, warning = slightly over, error = very over, dash =
/// no data) so colour is never the only channel.
///
/// Both periods stop at yesterday, so this line does not swing every time a
/// meal is logged today -- it answers "how has this week gone", not "how am I
/// doing right now", which is what the Today progress card is for.
class AverageSummaryRow extends StatelessWidget {
  /// Creates an [AverageSummaryRow].
  const AverageSummaryRow({required this.week, required this.month, super.key});

  /// The current ISO week's average, through yesterday.
  final PeriodAverage week;

  /// The current calendar month's average, through yesterday.
  final PeriodAverage month;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _PeriodFigure(
          period: week,
          icon: Icons.calendar_view_week,
          semanticLabel: 'week',
        ),
        const SizedBox(width: 24),
        _PeriodFigure(
          period: month,
          icon: Icons.calendar_view_month,
          semanticLabel: 'month',
        ),
      ],
    );
  }
}

class _PeriodFigure extends StatelessWidget {
  const _PeriodFigure({
    required this.period,
    required this.icon,
    required this.semanticLabel,
  });

  final PeriodAverage period;
  final IconData icon;
  final String semanticLabel;

  (CueKind, IconData) get _band => switch (period.band) {
    null => (CueKind.info, Icons.remove_circle_outline),
    AverageBand.under => (CueKind.ok, Icons.check_circle),
    AverageBand.slightlyOver => (CueKind.warn, Icons.warning_amber_rounded),
    AverageBand.veryOver => (CueKind.error, Icons.error),
  };

  @override
  Widget build(BuildContext context) {
    final (kind, bandIcon) = _band;
    final avg = period.avgKcal;
    final style = Theme.of(context).textTheme.bodySmall;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, semanticLabel: semanticLabel),
        const SizedBox(width: 4),
        Icon(
          bandIcon,
          size: 16,
          color: kind.tint(context),
          semanticLabel: bandLabel(period.band),
        ),
        if (avg != null) ...[
          const SizedBox(width: 4),
          Icon(
            MacroKind.kcal.icon,
            size: 14,
            color: MacroKind.kcal.color,
            semanticLabel: 'kcal',
          ),
          Text('${avg.round()}', style: style),
        ],
      ],
    );
  }
}
