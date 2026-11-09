/// Icon-only chrome shared by the history and food-bank filter sheets: the
/// clear control, the apply bar and the sort chooser. Each control paints a
/// glyph and speaks its old caption only through its semantic label.
library;

import 'package:flutter/material.dart';

/// Top row of a filter sheet: one clear-everything icon, right-aligned.
class FilterSheetHeader extends StatelessWidget {
  /// Creates a header whose clear icon calls [onClear].
  const FilterSheetHeader({required this.onClear, super.key});

  /// Called when the clear icon is pressed.
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
    child: Align(
      alignment: Alignment.centerRight,
      child: IconButton(
        icon: const Icon(Icons.filter_list_off, semanticLabel: 'Clear all'),
        onPressed: onClear,
      ),
    ),
  );
}

/// Bottom bar of a filter sheet: one full-width check button.
class FilterApplyBar extends StatelessWidget {
  /// Creates an apply bar that calls [onApply].
  const FilterApplyBar({required this.onApply, super.key});

  /// Called when the check is pressed.
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onApply,
        child: const Icon(Icons.check, semanticLabel: 'Apply'),
      ),
    ),
  );
}

/// One choice in a [SortChoiceRow]: a glyph, its tint and its spoken name.
class SortOption<T> {
  /// Creates an option selecting [value].
  const SortOption(this.value, this.icon, this.semanticLabel, {this.color});

  /// The value reported when chosen.
  final T value;

  /// Painted glyph.
  final IconData icon;

  /// Spoken name; never painted.
  final String semanticLabel;

  /// Glyph tint; the theme default when null.
  final Color? color;
}

/// Icon chips for the sort field plus an arrow for the direction.
class SortChoiceRow<T> extends StatelessWidget {
  /// Creates a chooser over [options] with [selected] active.
  const SortChoiceRow({
    required this.options,
    required this.selected,
    required this.ascending,
    required this.onChanged,
    super.key,
  });

  /// Choices in display order.
  final List<SortOption<T>> options;

  /// The active choice.
  final T selected;

  /// Whether the sort runs ascending.
  final bool ascending;

  /// Called with the new field and direction.
  final void Function({required T field, required bool asc}) onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final o in options)
                ChoiceChip(
                  label: Icon(
                    o.icon,
                    size: 18,
                    color: o.color,
                    semanticLabel: o.semanticLabel,
                  ),
                  selected: selected == o.value,
                  onSelected: (_) => onChanged(field: o.value, asc: ascending),
                ),
            ],
          ),
        ),
        IconButton(
          icon: Icon(
            ascending ? Icons.arrow_upward : Icons.arrow_downward,
            semanticLabel: ascending ? 'Ascending' : 'Descending',
          ),
          onPressed: () => onChanged(field: selected, asc: !ascending),
        ),
      ],
    );
  }
}
