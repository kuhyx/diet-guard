/// The source-chip and sort controls at the foot of the history filter sheet.
///
/// Split from `history_filter_sheet.dart` for the repo's 250-line cap. Both are
/// stateless and report upward: the live filter and sort order belong to the
/// screen, so nothing here holds state that could disagree with what is shown.
/// Every control is a glyph; its old caption lives only in the semantic label.
library;

import 'package:diet_guard_app/ui/macro_kind.dart';
import 'package:diet_guard_app/ui/source_icon.dart';
import 'package:diet_guard_app/widgets/filters/filter_chrome.dart';
import 'package:diet_guard_app/widgets/history/history_filter.dart';
import 'package:flutter/material.dart';

/// The known `source` values an entry can carry, in display order.
///
/// Kept next to the chips that render them rather than in the filter model:
/// this is a UI affordance (which sources are worth offering as one tap), not
/// a constraint on what `source` may contain.
const _sources = ['manual', 'food bank'];

/// Single-select chips filtering by entry source, with an "all" reset.
class FilterSourceChips extends StatelessWidget {
  /// Creates source chips with [selected] currently active.
  const FilterSourceChips({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  /// The active source, or null for "all".
  final String? selected;

  /// Called with the chosen source, or null when the reset chip is tapped.
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: [
        FilterChip(
          label: const Icon(
            Icons.all_inclusive,
            size: 18,
            semanticLabel: 'All',
          ),
          selected: selected == null,
          onSelected: (_) => onSelected(null),
        ),
        for (final src in _sources)
          FilterChip(
            label: SourceMark(src, size: 18),
            selected: selected == src,
            onSelected: (_) => onSelected(src),
          ),
      ],
    );
  }
}

/// The sort-field chips plus their ascending/descending toggle.
class FilterSortControls extends StatelessWidget {
  /// Creates sort controls reflecting [sortField] and [ascending].
  const FilterSortControls({
    required this.sortField,
    required this.ascending,
    required this.onSortChanged,
    super.key,
  });

  /// The field the list is currently sorted by.
  final HistorySortField sortField;

  /// Whether the sort currently runs ascending.
  final bool ascending;

  /// Called when either the field or the direction changes.
  final void Function({required HistorySortField field, required bool asc})
  onSortChanged;

  static final List<SortOption<HistorySortField>> _options = [
    const SortOption(HistorySortField.date, Icons.calendar_today, 'Date'),
    SortOption(
      HistorySortField.kcal,
      MacroKind.kcal.icon,
      'Kcal',
      color: MacroKind.kcal.color,
    ),
    SortOption(
      HistorySortField.protein,
      MacroKind.protein.icon,
      'Protein',
      color: MacroKind.protein.color,
    ),
    SortOption(
      HistorySortField.carbs,
      MacroKind.carbs.icon,
      'Carbs',
      color: MacroKind.carbs.color,
    ),
    SortOption(
      HistorySortField.fat,
      MacroKind.fat.icon,
      'Fat',
      color: MacroKind.fat.color,
    ),
    const SortOption(
      HistorySortField.description,
      Icons.sort_by_alpha,
      'Description',
    ),
  ];

  @override
  Widget build(BuildContext context) => SortChoiceRow<HistorySortField>(
    options: _options,
    selected: sortField,
    ascending: ascending,
    onChanged: onSortChanged,
  );
}
