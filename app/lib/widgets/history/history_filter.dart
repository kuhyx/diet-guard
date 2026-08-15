/// Filter, sort and grouping model for the history screen.
///
/// Split out of `history_screen.dart` to hold the repo's 250-line cap. This is
/// the pure-data half -- no widgets -- so the sheet, the list and the screen
/// can each depend on it without depending on one another.
library;

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Filter & sort state
// ---------------------------------------------------------------------------

/// Sort field for the history list.
enum HistorySortField {
  /// Sort by entry date/time.
  date,

  /// Sort by calories.
  kcal,

  /// Sort by protein (g).
  protein,

  /// Sort by carbohydrates (g).
  carbs,

  /// Sort by fat (g).
  fat,

  /// Sort by description text.
  description,
}

/// All active filter criteria; [isActive] is true when any criterion is set.
class HistoryFilter {
  /// Creates a [HistoryFilter] with the given criteria.
  HistoryFilter({
    this.nameQuery = '',
    this.dateRange,
    this.minKcal,
    this.maxKcal,
    this.minProtein,
    this.maxProtein,
    this.minCarbs,
    this.maxCarbs,
    this.minFat,
    this.maxFat,
    this.source,
  });

  /// Substring match on the food description.
  String nameQuery;

  /// Optional date range filter.
  DateTimeRange? dateRange;

  /// Minimum kcal.
  double? minKcal;

  /// Maximum kcal.
  double? maxKcal;

  /// Minimum protein (g).
  double? minProtein;

  /// Maximum protein (g).
  double? maxProtein;

  /// Minimum carbs (g).
  double? minCarbs;

  /// Maximum carbs (g).
  double? maxCarbs;

  /// Minimum fat (g).
  double? minFat;

  /// Maximum fat (g).
  double? maxFat;

  /// null = all, or a source string from the log.
  String? source;

  /// True when any filter criterion is active.
  bool get isActive =>
      nameQuery.isNotEmpty ||
      dateRange != null ||
      minKcal != null ||
      maxKcal != null ||
      minProtein != null ||
      maxProtein != null ||
      minCarbs != null ||
      maxCarbs != null ||
      minFat != null ||
      maxFat != null ||
      source != null;
}

// ---------------------------------------------------------------------------
// List item sealed hierarchy for day-grouped rendering
// ---------------------------------------------------------------------------
