/// Filter and sort model for the food bank browser.
///
/// Split out of `food_bank_screen.dart` for the repo's 250-line cap. Pure data
/// -- no widgets -- so the sheet, the list and the screen can each depend on it
/// without depending on one another.
library;

import 'package:diet_guard_app/models/food_bank_record.dart';

/// Sort field for the food bank list.
enum FbSortField {
  /// Sort alphabetically by name.
  name,

  /// Sort by calories.
  kcal,

  /// Sort by protein (g).
  protein,

  /// Sort by carbohydrates (g).
  carbs,

  /// Sort by fat (g).
  fat,

  /// Sort by usage count (most-used first by default).
  count,
}

/// Active filter criteria for the food bank list.
class FbFilter {
  /// Creates a [FbFilter] with the given criteria.
  FbFilter({
    this.nameQuery = '',
    this.minKcal,
    this.maxKcal,
    this.minProtein,
    this.maxProtein,
    this.minCarbs,
    this.maxCarbs,
    this.minFat,
    this.maxFat,
  });

  /// Substring match on the food name.
  String nameQuery;

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

  /// True when any criterion is set.
  bool get isActive =>
      nameQuery.isNotEmpty ||
      minKcal != null ||
      maxKcal != null ||
      minProtein != null ||
      maxProtein != null ||
      minCarbs != null ||
      maxCarbs != null ||
      minFat != null ||
      maxFat != null;
}

// ---------------------------------------------------------------------------
// Pure filter / sort helper
// ---------------------------------------------------------------------------

/// Filters and sorts [entries] by [filter] and [sortField]/[ascending].
///
/// Exposed as a top-level function for unit tests.
List<FoodBankRecord> applyFbFilter(
  List<FoodBankRecord> entries,
  FbFilter filter,
  FbSortField sortField, {
  required bool ascending,
}) {
  var result = [...entries];
  if (filter.nameQuery.isNotEmpty) {
    final q = filter.nameQuery.toLowerCase();
    result = result.where((e) => e.desc.toLowerCase().contains(q)).toList();
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

  result.sort((a, b) {
    int cmp;
    switch (sortField) {
      case FbSortField.name:
        cmp = a.desc.compareTo(b.desc);
      case FbSortField.kcal:
        cmp = a.kcal.compareTo(b.kcal);
      case FbSortField.protein:
        cmp = a.proteinG.compareTo(b.proteinG);
      case FbSortField.carbs:
        cmp = a.carbsG.compareTo(b.carbsG);
      case FbSortField.fat:
        cmp = a.fatG.compareTo(b.fatG);
      case FbSortField.count:
        cmp = a.count.compareTo(b.count);
    }
    return ascending ? cmp : -cmp;
  });

  return result;
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// Lists all food bank entries (log-derived + manual) with filtering/sorting
/// and a FAB for adding new manual entries.
