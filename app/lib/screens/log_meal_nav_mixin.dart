import 'package:diet_guard_app/screens/calendar_screen.dart';
import 'package:diet_guard_app/screens/food_bank_screen.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// The four app-bar destinations reachable from [LogMealScreen].
///
/// Split out of `log_meal_screen.dart` for the repo's 250-line cap. The routes
/// are unchanged -- each pushes exactly the [MaterialPageRoute] it did before.
mixin LogMealNavMixin<T extends StatefulWidget> on State<T> {
  /// The screen's injected HTTP client, forwarded to [SettingsScreen].
  http.Client? get syncHttpClient;

  /// Re-reads the meal schedule and today's logged slots.
  ///
  /// Called when [SettingsScreen] pops, because the schedule editor lives
  /// there: without it the slot row keeps rendering the schedule that was in
  /// force when this screen was built, so switching from four meals to five
  /// showed the old four checkpoints until the app was restarted. Verified on
  /// the phone -- the settings preview and the reminder both updated while the
  /// row behind them did not.
  Future<void> onScheduleMayHaveChanged();

  /// Pushes the entry history screen.
  void onOpenHistory() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const HistoryScreen()),
    );
  }

  /// Pushes the adherence calendar screen.
  void onOpenCalendar() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const CalendarScreen()),
    );
  }

  /// Pushes the food bank screen.
  void onOpenFoodBank() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const FoodBankScreen()),
    );
  }

  /// Pushes the settings screen, forwarding the HTTP client.
  ///
  /// Awaits the pop, unlike the other three: settings owns the meal-schedule
  /// editor, so the slot row has to be rebuilt against whatever the user
  /// chose there.
  Future<void> onOpenSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(httpClient: syncHttpClient),
      ),
    );
    if (!mounted) return;
    await onScheduleMayHaveChanged();
  }
}
