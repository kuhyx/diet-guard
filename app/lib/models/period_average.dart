/// Value types for a period's average intake and its budget band.
library;

import 'package:flutter/foundation.dart';

/// How a period's average intake compared with its average budget.
///
/// Kept in sync with `diet_guard/_averages.py`'s `AverageBand`.
enum AverageBand {
  /// Average intake at or below the average budget.
  under,

  /// Above budget, but no more than 20% above.
  slightlyOver,

  /// More than 20% above budget.
  veryOver,
}

/// The human phrase for [band], or `'no data'` when it is null.
///
/// Byte-identical to `_averages.band_label` so the phone and the PC gate never
/// describe the same week with different words.
String bandLabel(AverageBand? band) => switch (band) {
  null => 'no data',
  AverageBand.under => 'under',
  AverageBand.slightlyOver => 'slightly over',
  AverageBand.veryOver => 'very over',
};

/// One period's mean intake and how it compared with the mean budget.
@immutable
class PeriodAverage {
  /// Creates a [PeriodAverage].
  const PeriodAverage({
    required this.start,
    required this.end,
    required this.loggedDays,
    required this.elapsedDays,
    required this.avgKcal,
    required this.avgBudget,
    required this.band,
  });

  /// An entirely empty period, for a screen that has not loaded yet.
  static const empty = PeriodAverage(
    start: '',
    end: '',
    loggedDays: 0,
    elapsedDays: 0,
    avgKcal: null,
    avgBudget: null,
    band: null,
  );

  /// `YYYY-MM-DD`, the period's first day (inclusive).
  final String start;

  /// `YYYY-MM-DD`, the period's last *complete* day (inclusive); earlier than
  /// [start] when the period has none yet.
  final String end;

  /// Days in the range carrying at least one valid, non-tombstoned entry.
  final int loggedDays;

  /// Complete days in the range, logged or not.
  final int elapsedDays;

  /// Mean kcal across [loggedDays], or null when that is zero.
  final double? avgKcal;

  /// Mean daily budget across those same days, or null.
  final double? avgBudget;

  /// The band, or null when there is nothing to judge.
  final AverageBand? band;

  @override
  bool operator ==(Object other) =>
      other is PeriodAverage &&
      other.start == start &&
      other.end == end &&
      other.loggedDays == loggedDays &&
      other.elapsedDays == elapsedDays &&
      other.avgKcal == avgKcal &&
      other.avgBudget == avgBudget &&
      other.band == band;

  @override
  int get hashCode => Object.hash(
    start,
    end,
    loggedDays,
    elapsedDays,
    avgKcal,
    avgBudget,
    band,
  );

  @override
  String toString() =>
      'PeriodAverage($start..$end, $avgKcal kcal over $loggedDays/'
      '$elapsedDays days, ${bandLabel(band)})';
}
