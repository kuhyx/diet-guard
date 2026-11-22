import 'package:diet_guard_app/screens/log_meal_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('logMealAppBarActions tooltips name each icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: logMealAppBarActions(
              onFoodBank: () {},
              onHistory: () {},
              onCalendar: () {},
              onSettings: () {},
              onBody: () {},
            ),
          ),
        ),
      ),
    );

    for (final label in ['Body', 'Foods', 'History', 'Calendar', 'Sync']) {
      expect(find.byTooltip(label), findsOneWidget, reason: label);
    }
  });
}
