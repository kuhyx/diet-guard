/// Weekly/monthly average-intake summary row for the History screen.
library;

import 'package:diet_guard_app/models/period_average.dart';
import 'package:flutter/material.dart';

/// Displays this week's and this month's average kcal/day and their bands.
///
/// Mirrors `_calendar_view.py`'s `averages_text`: "Avg/day (to yesterday):
/// week NNNN kcal (band) · month NNNN kcal (band)".
///
/// Both periods stop at yesterday, so this line does not swing every time a
/// meal is logged today -- it answers "how has this week gone", not "how am I
/// doing right now", which is what the Today progress card is for.
class AverageSummaryRow extends StatelessWidget {
  /// Creates an [AverageSummaryRow].
  const AverageSummaryRow({
    required this.week,
    required this.month,
    super.key,
  });

  /// The current ISO week's average, through yesterday.
  final PeriodAverage week;

  /// The current calendar month's average, through yesterday.
  final PeriodAverage month;

  static String _part(PeriodAverage period) {
    final avg = period.avgKcal;
    if (avg == null) return bandLabel(period.band);
    return '${avg.round()} kcal (${bandLabel(period.band)})';
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      'Avg/day (to yesterday): week ${_part(week)}  ·  month ${_part(month)}',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}
