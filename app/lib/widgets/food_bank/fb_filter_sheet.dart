/// The bottom sheet that edits an [FbFilter].
///
/// Split out of `food_bank_screen.dart` for the repo's 250-line cap. The macro
/// range rows come from `widgets/filters/`, shared with the history sheet.
library;

import 'package:diet_guard_app/widgets/filters/filter_fields.dart';
import 'package:diet_guard_app/widgets/food_bank/fb_filter.dart';
import 'package:flutter/material.dart';

/// The draggable bottom sheet that edits the food bank's filter and sort order.
///
/// Stateless on purpose: the live [FbFilter] belongs to the screen, and every
/// edit goes back out through [onFilterChanged] rather than being held here.
class FbFilterSheet extends StatelessWidget {
  /// Creates an [FbFilterSheet] over the screen's current filter/sort state.
  const FbFilterSheet({
    required this.filter,
    required this.sortField,
    required this.ascending,
    required this.maxKcal,
    required this.maxProtein,
    required this.maxCarbs,
    required this.maxFat,
    required this.onFilterChanged,
    required this.onSortChanged,
    required this.onApply,
    required this.onClear,
    super.key,
  });

  /// The filter criteria currently being edited.
  final FbFilter filter;

  /// The field the list is sorted by.
  final FbSortField sortField;

  /// Whether the sort runs ascending.
  final bool ascending;

  /// Upper bound of the calories slider, from the banked records.
  final double maxKcal;

  /// Upper bound of the protein slider, from the banked records.
  final double maxProtein;

  /// Upper bound of the carbohydrate slider, from the banked records.
  final double maxCarbs;

  /// Upper bound of the fat slider, from the banked records.
  final double maxFat;

  /// Called with a new filter on every edit.
  final void Function(FbFilter) onFilterChanged;

  /// Called when the sort field or direction changes.
  final void Function({required FbSortField field, required bool asc})
  onSortChanged;

  /// Called when the user applies the filter and dismisses the sheet.
  final VoidCallback onApply;

  /// Called when the user clears every criterion.
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Filter & Sort',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: onClear,
                  child: const Text('Clear all'),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Search by name',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                  controller: TextEditingController(text: filter.nameQuery)
                    ..selection = TextSelection.collapsed(
                      offset: filter.nameQuery.length,
                    ),
                  onChanged: (v) {
                    filter.nameQuery = v;
                    onFilterChanged(filter);
                  },
                ),
                const SizedBox(height: 16),
                FilterRangeRow(
                  label: 'Kcal range',
                  sliderKey: const Key('fb-kcal-range-slider'),
                  maxValue: maxKcal,
                  min: filter.minKcal,
                  max: filter.maxKcal,
                  showEndpointLabels: false,
                  onChanged: (lo, hi) {
                    filter.minKcal = lo;
                    filter.maxKcal = hi;
                    onFilterChanged(filter);
                  },
                ),
                FilterRangeRow(
                  label: 'Protein range (g)',
                  sliderKey: const Key('fb-protein-range-slider'),
                  maxValue: maxProtein,
                  min: filter.minProtein,
                  max: filter.maxProtein,
                  unit: 'g',
                  showEndpointLabels: false,
                  onChanged: (lo, hi) {
                    filter.minProtein = lo;
                    filter.maxProtein = hi;
                    onFilterChanged(filter);
                  },
                ),
                FilterRangeRow(
                  label: 'Carbs range (g)',
                  sliderKey: const Key('fb-carbs-range-slider'),
                  maxValue: maxCarbs,
                  min: filter.minCarbs,
                  max: filter.maxCarbs,
                  unit: 'g',
                  showEndpointLabels: false,
                  onChanged: (lo, hi) {
                    filter.minCarbs = lo;
                    filter.maxCarbs = hi;
                    onFilterChanged(filter);
                  },
                ),
                FilterRangeRow(
                  label: 'Fat range (g)',
                  sliderKey: const Key('fb-fat-range-slider'),
                  maxValue: maxFat,
                  min: filter.minFat,
                  max: filter.maxFat,
                  unit: 'g',
                  showEndpointLabels: false,
                  onChanged: (lo, hi) {
                    filter.minFat = lo;
                    filter.maxFat = hi;
                    onFilterChanged(filter);
                  },
                ),
                Text(
                  'Sort by',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButton<FbSortField>(
                        isExpanded: true,
                        value: sortField,
                        items: const [
                          DropdownMenuItem(
                            value: FbSortField.count,
                            child: Text('Usage count'),
                          ),
                          DropdownMenuItem(
                            value: FbSortField.name,
                            child: Text('Name'),
                          ),
                          DropdownMenuItem(
                            value: FbSortField.kcal,
                            child: Text('Kcal'),
                          ),
                          DropdownMenuItem(
                            value: FbSortField.protein,
                            child: Text('Protein'),
                          ),
                          DropdownMenuItem(
                            value: FbSortField.carbs,
                            child: Text('Carbs'),
                          ),
                          DropdownMenuItem(
                            value: FbSortField.fat,
                            child: Text('Fat'),
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
                      onPressed: () =>
                          onSortChanged(field: sortField, asc: !ascending),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onApply,
                child: const Text('Apply'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Add entry dialog
// ---------------------------------------------------------------------------
