import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/screens/log_meal_progress.dart';
import 'package:diet_guard_app/widgets/macro_input_row.dart';
import 'package:flutter/material.dart';

/// Builds the [Nutrition] for a submit from the form's macro controllers.
///
/// Split out of `log_meal_screen.dart` for the repo's 250-line cap. Pure over
/// its inputs, so the per-portion scaling is testable without a widget.
Nutrition nutritionFromControllers(MacroControllers macros, String source) =>
    nutritionForPortion(
      kcal: parseMacroField(macros.kcal),
      proteinG: parseMacroField(macros.protein),
      carbsG: parseMacroField(macros.carbs),
      fatG: parseMacroField(macros.fat),
      perGrams: parseMacroField(macros.perGrams),
      ateGrams: parseMacroField(macros.grams),
      source: source,
    );

/// The four destination buttons in [LogMealScreen]'s app bar.
///
/// Split out of `log_meal_screen.dart` for the repo's 250-line cap. Returned
/// as a list to be spread into `AppBar.actions`, so the bar's structure and
/// the order of the buttons are unchanged.
List<Widget> logMealAppBarActions({
  required VoidCallback onFoodBank,
  required VoidCallback onHistory,
  required VoidCallback onCalendar,
  required VoidCallback onSettings,
}) => [
  IconButton(
    icon: const Icon(Icons.restaurant_menu),
    tooltip: 'Food bank',
    onPressed: onFoodBank,
  ),
  IconButton(
    icon: const Icon(Icons.history),
    tooltip: 'History',
    onPressed: onHistory,
  ),
  IconButton(
    icon: const Icon(Icons.calendar_month),
    tooltip: 'Calendar',
    onPressed: onCalendar,
  ),
  IconButton(
    icon: const Icon(Icons.settings),
    tooltip: 'Sync settings',
    onPressed: onSettings,
  ),
];
