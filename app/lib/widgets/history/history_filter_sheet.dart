/// The bottom sheet that edits a [HistoryFilter].
///
/// Split out of `history_screen.dart` to hold the repo's 250-line cap.
library;

import 'package:diet_guard_app/widgets/filters/filter_fields.dart';
import 'package:diet_guard_app/widgets/history/history_filter.dart';
import 'package:diet_guard_app/widgets/history/history_filter_sort.dart';
import 'package:diet_guard_app/widgets/history/history_grouping.dart';
import 'package:flutter/material.dart';

/// The draggable bottom sheet that edits the history filter and sort order.
///
/// Stateless on purpose: the live [HistoryFilter] belongs to the screen, and
/// every edit goes back out through [onFilterChanged] rather than being held
/// here, so "apply" and "clear" cannot disagree with what is displayed.
class FilterSheet extends StatelessWidget {
  /// Creates a [FilterSheet] over the screen's current filter and sort state.
  const FilterSheet({
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
  final HistoryFilter filter;

  /// The field the list is sorted by.
  final HistorySortField sortField;

  /// Whether the sort runs ascending.
  final bool ascending;

  /// Upper bound of the calories slider, from the logged data.
  final double maxKcal;

  /// Upper bound of the protein slider, from the logged data.
  final double maxProtein;

  /// Upper bound of the carbohydrate slider, from the logged data.
  final double maxCarbs;

  /// Upper bound of the fat slider, from the logged data.
  final double maxFat;

  /// Called with a new filter on every edit.
  final void Function(HistoryFilter) onFilterChanged;

  /// Called when the sort field or direction changes.
  final void Function({required HistorySortField field, required bool asc})
  onSortChanged;

  /// Called when the user applies the filter and dismisses the sheet.
  final VoidCallback onApply;

  /// Called when the user clears every criterion.
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
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
                TextButton(onPressed: onClear, child: const Text('Clear all')),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: SingleChildScrollView(
              controller: scroll,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Name search
                  NameSearchField(
                    initialQuery: filter.nameQuery,
                    onChanged: (v) {
                      filter.nameQuery = v;
                      onFilterChanged(filter);
                    },
                  ),
                  const SizedBox(height: 16),

                  // Date range
                  Text(
                    'Date range',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.date_range),
                    label: Text(
                      filter.dateRange == null
                          ? 'Any date'
                          : dateRangeLabel(filter.dateRange!),
                    ),
                    onPressed: () async {
                      final picked = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now().add(const Duration(days: 1)),
                        initialDateRange: filter.dateRange,
                      );
                      if (picked != null) {
                        filter.dateRange = picked;
                        onFilterChanged(filter);
                      }
                    },
                  ),
                  if (filter.dateRange != null)
                    TextButton(
                      onPressed: () {
                        filter.dateRange = null;
                        onFilterChanged(filter);
                      },
                      child: const Text('Clear date range'),
                    ),
                  const SizedBox(height: 16),

                  FilterRangeRow(
                    label: 'Kcal range',
                    sliderKey: const Key('kcal-range-slider'),
                    maxValue: maxKcal,
                    min: filter.minKcal,
                    max: filter.maxKcal,
                    onChanged: (lo, hi) {
                      filter.minKcal = lo;
                      filter.maxKcal = hi;
                      onFilterChanged(filter);
                    },
                  ),
                  FilterRangeRow(
                    label: 'Protein range (g)',
                    sliderKey: const Key('protein-range-slider'),
                    maxValue: maxProtein,
                    min: filter.minProtein,
                    max: filter.maxProtein,
                    unit: 'g',
                    onChanged: (lo, hi) {
                      filter.minProtein = lo;
                      filter.maxProtein = hi;
                      onFilterChanged(filter);
                    },
                  ),
                  FilterRangeRow(
                    label: 'Carbs range (g)',
                    sliderKey: const Key('carbs-range-slider'),
                    maxValue: maxCarbs,
                    min: filter.minCarbs,
                    max: filter.maxCarbs,
                    unit: 'g',
                    onChanged: (lo, hi) {
                      filter.minCarbs = lo;
                      filter.maxCarbs = hi;
                      onFilterChanged(filter);
                    },
                  ),
                  FilterRangeRow(
                    label: 'Fat range (g)',
                    sliderKey: const Key('fat-range-slider'),
                    maxValue: maxFat,
                    min: filter.minFat,
                    max: filter.maxFat,
                    unit: 'g',
                    onChanged: (lo, hi) {
                      filter.minFat = lo;
                      filter.maxFat = hi;
                      onFilterChanged(filter);
                    },
                  ),

                  FilterSourceChips(
                    selected: filter.source,
                    onSelected: (src) {
                      filter.source = src;
                      onFilterChanged(filter);
                    },
                  ),
                  const SizedBox(height: 16),
                  FilterSortControls(
                    sortField: sortField,
                    ascending: ascending,
                    onSortChanged: onSortChanged,
                  ),
                ],
              ),
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
// Slider label helpers
// ---------------------------------------------------------------------------

/// Thin row showing the min (0) and max endpoint values for a range slider.
/// The filter sheet's name-search field, owning a persistent controller.
///
/// Stateful on purpose. The controller used to be built inside
/// `FilterSheet.build` with the caret forced to the end of the text, and
/// `onChanged` rebuilds the sheet — so every keystroke discarded the controller
/// and re-slammed the caret to end-of-text. Appending worked, but Home/End and
/// arrow-key editing in the middle of the query were silently undone on each
/// character. Keeping the controller in State fixes that without changing how
/// the filter is plumbed.
