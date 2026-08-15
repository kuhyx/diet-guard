import 'package:flutter/material.dart';

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
