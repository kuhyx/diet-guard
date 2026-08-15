/// The source-chip and sort controls at the foot of the history filter sheet.
///
/// Split from `history_filter_sheet.dart` for the repo's 250-line cap. Both are
/// stateless and report upward: the live filter and sort order belong to the
/// screen, so nothing here holds state that could disagree with what is shown.
library;

import 'package:diet_guard_app/widgets/history/history_filter.dart';
import 'package:flutter/material.dart';

/// The known `source` values an entry can carry, in display order.
///
/// Kept next to the chips that render them rather than in the filter model:
/// this is a UI affordance (which sources are worth offering as one tap), not
/// a constraint on what `source` may contain.
const _sources = ['manual', 'food bank'];

/// Single-select chips filtering by entry source, with an "All" reset.
class FilterSourceChips extends StatelessWidget {
  /// Creates source chips with [selected] currently active.
  const FilterSourceChips({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  /// The active source, or null for "All".
  final String? selected;

  /// Called with the chosen source, or null when "All" is tapped.
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Source', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            FilterChip(
              label: const Text('All'),
              selected: selected == null,
              onSelected: (_) => onSelected(null),
            ),
            for (final src in _sources)
              FilterChip(
                label: Text(src),
                selected: selected == src,
                onSelected: (_) => onSelected(src),
              ),
          ],
        ),
      ],
    );
  }
}

/// The sort-field dropdown plus its ascending/descending toggle.
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Sort by', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: DropdownButton<HistorySortField>(
                isExpanded: true,
                value: sortField,
                items: const [
                  DropdownMenuItem(
                    value: HistorySortField.date,
                    child: Text('Date'),
                  ),
                  DropdownMenuItem(
                    value: HistorySortField.kcal,
                    child: Text('Kcal'),
                  ),
                  DropdownMenuItem(
                    value: HistorySortField.protein,
                    child: Text('Protein'),
                  ),
                  DropdownMenuItem(
                    value: HistorySortField.carbs,
                    child: Text('Carbs'),
                  ),
                  DropdownMenuItem(
                    value: HistorySortField.fat,
                    child: Text('Fat'),
                  ),
                  DropdownMenuItem(
                    value: HistorySortField.description,
                    child: Text('Description'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) {
                    onSortChanged(field: v, asc: ascending);
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(
                ascending ? Icons.arrow_upward : Icons.arrow_downward,
              ),
              tooltip: ascending ? 'Ascending' : 'Descending',
              onPressed: () => onSortChanged(field: sortField, asc: !ascending),
            ),
          ],
        ),
      ],
    );
  }
}
