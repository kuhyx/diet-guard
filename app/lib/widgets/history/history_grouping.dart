/// Grouping, filtering and day-label helpers for the history list.
///
/// Split from `history_filter.dart` for the repo's 250-line cap: that file is
/// the filter *criteria*, this one is what those criteria do to a list.
library;

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/day_status_service.dart';
import 'package:diet_guard_app/widgets/history/history_filter.dart';
import 'package:flutter/material.dart';

/// One row in the flattened history list: either a [DayHeader] or an
/// [EntryRow]. Sealed so the list's `switch` stays exhaustive.
sealed class HistoryItem {}

/// A day's summary row, shown above that day's entries.
final class DayHeader extends HistoryItem {
  /// Creates a [DayHeader] with a day's pre-computed totals.
  DayHeader(
    this.dateKey,
    this.totalKcal,
    this.entryCount,
    this.totalProtein,
    this.totalCarbs,
    this.totalFat,
  );

  /// The `YYYY-MM-DD` key this header groups.
  final String dateKey;

  /// Calories logged across the whole day.
  final double totalKcal;

  /// How many entries the day holds.
  final int entryCount;

  /// Protein grams logged across the whole day.
  final double totalProtein;

  /// Carbohydrate grams logged across the whole day.
  final double totalCarbs;

  /// Fat grams logged across the whole day.
  final double totalFat;
}

/// A single logged meal within a day's group.
final class EntryRow extends HistoryItem {
  /// Creates an [EntryRow] wrapping [entry].
  EntryRow(this.entry);

  /// The entry this row renders.
  final FoodEntry entry;
}

// ---------------------------------------------------------------------------
// Pure filter / sort / group helpers
// ---------------------------------------------------------------------------

/// Applies [filter] and sort criteria to [entries] and returns the result.
///
/// Exposed as a top-level function for unit tests.
List<FoodEntry> applyHistoryFilter(
  List<FoodEntry> entries,
  HistoryFilter filter,
  HistorySortField sortField, {
  required bool ascending,
}) {
  var result = [...entries];

  if (filter.nameQuery.isNotEmpty) {
    final q = filter.nameQuery.toLowerCase();
    result = result.where((e) => e.desc.toLowerCase().contains(q)).toList();
  }
  if (filter.dateRange != null) {
    final start = filter.dateRange!.start;
    final end = filter.dateRange!.end.add(const Duration(days: 1));
    result = result.where((e) {
      final t = DateTime.tryParse(e.time);
      return t != null && !t.isBefore(start) && t.isBefore(end);
    }).toList();
  }
  if (filter.minKcal != null) {
    result = result.where((e) => e.kcal >= filter.minKcal!).toList();
  }
  if (filter.maxKcal != null) {
    result = result.where((e) => e.kcal <= filter.maxKcal!).toList();
  }
  if (filter.minProtein != null) {
    result = result.where((e) => e.proteinG >= filter.minProtein!).toList();
  }
  if (filter.maxProtein != null) {
    result = result.where((e) => e.proteinG <= filter.maxProtein!).toList();
  }
  if (filter.minCarbs != null) {
    result = result.where((e) => e.carbsG >= filter.minCarbs!).toList();
  }
  if (filter.maxCarbs != null) {
    result = result.where((e) => e.carbsG <= filter.maxCarbs!).toList();
  }
  if (filter.minFat != null) {
    result = result.where((e) => e.fatG >= filter.minFat!).toList();
  }
  if (filter.maxFat != null) {
    result = result.where((e) => e.fatG <= filter.maxFat!).toList();
  }
  if (filter.source != null) {
    result = result.where((e) => e.source == filter.source).toList();
  }

  result.sort((a, b) {
    int cmp;
    switch (sortField) {
      case HistorySortField.date:
        final at = DateTime.tryParse(a.time) ?? DateTime(0);
        final bt = DateTime.tryParse(b.time) ?? DateTime(0);
        cmp = at.compareTo(bt);
      case HistorySortField.kcal:
        cmp = a.kcal.compareTo(b.kcal);
      case HistorySortField.protein:
        cmp = a.proteinG.compareTo(b.proteinG);
      case HistorySortField.carbs:
        cmp = a.carbsG.compareTo(b.carbsG);
      case HistorySortField.fat:
        cmp = a.fatG.compareTo(b.fatG);
      case HistorySortField.description:
        cmp = a.desc.compareTo(b.desc);
    }
    return ascending ? cmp : -cmp;
  });

  return result;
}

/// Flatten [entries] into day headers followed by that day's rows.
///
/// Each day's totals are summed once here rather than per-rebuild in the list.
List<HistoryItem> buildGroupedItems(List<FoodEntry> entries) {
  final byDay = <String, List<FoodEntry>>{};
  for (final e in entries) {
    final day = e.time.length >= 10 ? e.time.substring(0, 10) : 'unknown';
    byDay.putIfAbsent(day, () => []).add(e);
  }
  final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
  final items = <HistoryItem>[];
  for (final day in days) {
    final dayEntries = byDay[day]!;
    final totalKcal = sumKcal(dayEntries);
    final totalProtein = dayEntries.fold<double>(0, (s, e) => s + e.proteinG);
    final totalCarbs = dayEntries.fold<double>(0, (s, e) => s + e.carbsG);
    final totalFat = dayEntries.fold<double>(0, (s, e) => s + e.fatG);
    items
      ..add(
        DayHeader(
          day,
          totalKcal,
          dayEntries.length,
          totalProtein,
          totalCarbs,
          totalFat,
        ),
      )
      ..addAll(dayEntries.map(EntryRow.new));
  }
  return items;
}

/// Render a picked date range as `YYYY-MM-DD – YYYY-MM-DD` for the filter chip.
String dateRangeLabel(DateTimeRange r) =>
    '${r.start.toString().substring(0, 10)}'
    ' – ${r.end.toString().substring(0, 10)}';

/// Render a `YYYY-MM-DD` key as a short `Wed 12 Aug`-style label.
///
/// Falls back to the raw key when it cannot be parsed, so a malformed date
/// shows something rather than throwing inside a list build.
String formatDay(String dateKey) {
  try {
    final d = DateTime.parse(dateKey);
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${wd[d.weekday - 1]} ${d.day} ${mo[d.month - 1]} ${d.year}';
  } on Exception {
    return dateKey;
  }
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// Shows every non-deleted logged entry, grouped by day, with optional
/// filtering and sorting.
