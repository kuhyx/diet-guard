/// Renders ranked food-bank autocomplete suggestions.
library;

import 'package:diet_guard_app/models/food_suggestion.dart';
import 'package:diet_guard_app/ui/macro_kind.dart';
import 'package:material_ui/material_ui.dart';

/// A tappable list of [FoodSuggestion]s, each filling the form on tap.
///
/// When [compact] is true, only the top [compactLimit] suggestions render as
/// compact single-line rows, with a "N more" button opening the full list in a
/// bottom sheet so nothing becomes unreachable.
class AutocompleteSuggestionList extends StatelessWidget {
  /// Creates an [AutocompleteSuggestionList] for [suggestions].
  const AutocompleteSuggestionList({
    required this.suggestions,
    required this.onSelected,
    this.compact = false,
    this.compactLimit = 3,
    this.reserveHeight = false,
    super.key,
  });

  /// Ranked suggestions to display, best match first.
  final List<FoodSuggestion> suggestions;

  /// Called with the chosen suggestion when the user taps it.
  final ValueChanged<FoodSuggestion> onSelected;

  /// Whether to render a top-3 compact list with a "more" popup instead
  /// of the full unbounded list.
  final bool compact;

  /// How many rows a compact list shows before its "more" button.
  final int compactLimit;

  /// Whether a compact list always occupies [dueBlockHeight], empty or full,
  /// so nothing below it shifts as suggestions come and go (due mode).
  final bool reserveHeight;

  /// Height of the block that holds a compact list of two rows plus the
  /// "more" button; due mode reserves it so nothing below shifts.
  static const double dueBlockHeight = 120;

  Future<void> _showMore(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: AutocompleteSuggestionList(
          suggestions: suggestions,
          onSelected: (suggestion) {
            Navigator.of(sheetContext).pop();
            onSelected(suggestion);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _list(context);
    if (!reserveHeight) return list;
    return SizedBox(
      height: dueBlockHeight,
      child: Align(alignment: Alignment.topLeft, child: list),
    );
  }

  Widget _list(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();
    if (!compact) {
      return ListView.builder(
        shrinkWrap: true,
        itemCount: suggestions.length,
        itemBuilder: (context, index) {
          final suggestion = suggestions[index];
          return ListTile(
            dense: true,
            title: Text(suggestion.name),
            subtitle: Align(
              alignment: Alignment.centerLeft,
              child: MacroFigure(
                kind: MacroKind.kcal,
                value: suggestion.nutrition.kcal.toStringAsFixed(0),
              ),
            ),
            onTap: () => onSelected(suggestion),
          );
        },
      );
    }
    final shown = suggestions.take(compactLimit).toList();
    final remaining = suggestions.length - shown.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final suggestion in shown)
          InkWell(
            onTap: () => onSelected(suggestion),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      suggestion.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  MacroFigure(
                    kind: MacroKind.kcal,
                    value: suggestion.nutrition.kcal.toStringAsFixed(0),
                  ),
                ],
              ),
            ),
          ),
        if (remaining > 0)
          TextButton(
            onPressed: () => _showMore(context),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.more_horiz, semanticLabel: 'More'),
                const SizedBox(width: 4),
                Text('+$remaining'),
              ],
            ),
          ),
      ],
    );
  }
}
