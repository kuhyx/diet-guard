/// Per-day budget-adherence status and year-to-date tally value types.
library;

import 'package:flutter/foundation.dart';

/// Qualitative per-day budget-adherence state, worst to best.
///
/// Kept in sync with `diet_guard/_daystatus.py`'s `DayStatus`: not-logged is
/// considered worse than red, since an unlogged day carries no information
/// about whether it went well or badly.
enum DayStatus {
  /// No valid, non-tombstoned entries were logged for the day.
  notLogged,

  /// Logged, and more than 20% over budget.
  red,

  /// Logged, and up to 20% over budget.
  yellow,

  /// Logged, and at or under budget.
  green,
}

/// Year-to-date logging/adherence counts.
@immutable
class YtdTally {
  /// Creates a tally from its three component counts.
  const YtdTally({
    required this.loggedDays,
    required this.elapsedDays,
    required this.adherentDays,
  });

  /// Days this year with at least one valid log entry.
  final int loggedDays;

  /// Days from Jan 1 through the reference date, inclusive.
  final int elapsedDays;

  /// Of [loggedDays], how many were green or yellow.
  final int adherentDays;

  @override
  bool operator ==(Object other) =>
      other is YtdTally &&
      other.loggedDays == loggedDays &&
      other.elapsedDays == elapsedDays &&
      other.adherentDays == adherentDays;

  @override
  int get hashCode => Object.hash(loggedDays, elapsedDays, adherentDays);

  @override
  String toString() =>
      'YtdTally(logged: $loggedDays/$elapsedDays, adherent: $adherentDays)';
}
