/// Renders ranked food-bank autocomplete suggestions.
library;

import 'package:diet_guard_app/models/food_suggestion.dart';
import 'package:flutter/material.dart';

/// A tappable list of [FoodSuggestion]s, each filling the form on tap.
class AutocompleteSuggestionList extends StatelessWidget {
  /// Creates an [AutocompleteSuggestionList] for [suggestions].
  const AutocompleteSuggestionList({
    required this.suggestions,
    required this.onSelected,
    super.key,
  });

  /// Ranked suggestions to display, best match first.
  final List<FoodSuggestion> suggestions;

  /// Called with the chosen suggestion when the user taps it.
  final ValueChanged<FoodSuggestion> onSelected;

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return ListView.builder(
      shrinkWrap: true,
      itemCount: suggestions.length,
      itemBuilder: (context, index) {
        final suggestion = suggestions[index];
        return ListTile(
          dense: true,
          title: Text(suggestion.name),
          subtitle: Text(
            '${suggestion.nutrition.kcal.toStringAsFixed(0)} kcal',
          ),
          onTap: () => onSelected(suggestion),
        );
      },
    );
  }
}
