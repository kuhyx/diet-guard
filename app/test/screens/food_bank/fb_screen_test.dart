import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/screens/food_bank_screen.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/widgets/food_bank/fb_add_entry_dialog.dart';
import 'package:diet_guard_app/widgets/food_bank/fb_filter_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../label_finders.dart';
import 'fb_test_support.dart';

void main() {
  useTempFoodBankStores();
  testWidgets('shows empty-bank message when no entries exist', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      expect(byIconLabel('Food bank is empty.'), findsOneWidget);
    });
  });

  testWidgets('lists entries from the merged bank', (tester) async {
    await tester.runAsync(() async {
      await FoodBankService.instance.addManualEntry(
        const FoodBankRecord(
          desc: 'Manual oat',
          kcal: 370,
          proteinG: 13,
          carbsG: 66,
          fatG: 7,
          grams: 100,
          count: 0,
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      expect(find.text('Manual oat'), findsOneWidget);
    });
  });

  testWidgets('FAB opens add-entry dialog and saving adds to bank', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      await tester.tap(find.byType(FloatingActionButton));
      await settle(tester);

      expect(find.byType(AddEntryDialog), findsOneWidget);

      await tester.enterText(fieldByLabel('Name'), 'Test food');
      await tester.enterText(fieldByLabel('kcal'), '200');

      await tester.tap(byIconLabel('Save to bank'));
      await settle(tester);

      // After saving, the screen reloads and shows the new entry.
      expect(find.text('Test food'), findsOneWidget);
    });
  });

  testWidgets('dialog cancel does not save anything', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      await tester.tap(find.byType(FloatingActionButton));
      await settle(tester);

      await tester.tap(byIconLabel('Cancel'));
      await settle(tester);

      expect(byIconLabel('Food bank is empty.'), findsOneWidget);
    });
  });

  testWidgets('dialog save with empty name does nothing', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      await tester.tap(find.byType(FloatingActionButton));
      await settle(tester);

      // Tap save without entering a name.
      await tester.tap(byIconLabel('Save to bank'));
      await settle(tester);

      // Dialog stays open; no entry saved.
      expect(find.byType(AddEntryDialog), findsOneWidget);
    });
  });

  testWidgets('filter icon appears when entries exist', (tester) async {
    await tester.runAsync(() async {
      await FoodBankService.instance.addManualEntry(
        const FoodBankRecord(
          desc: 'Oat',
          kcal: 370,
          proteinG: 13,
          carbsG: 66,
          fatG: 7,
          grams: 100,
          count: 0,
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      expect(
        find.widgetWithIcon(IconButton, Icons.filter_list),
        findsOneWidget,
      );
    });
  });

  testWidgets('filter sheet opens and Apply filters results', (tester) async {
    await tester.runAsync(() async {
      await FoodBankService.instance.addManualEntry(
        const FoodBankRecord(
          desc: 'Oat',
          kcal: 370,
          proteinG: 13,
          carbsG: 66,
          fatG: 7,
          grams: 100,
          count: 0,
        ),
      );
      await FoodBankService.instance.addManualEntry(
        const FoodBankRecord(
          desc: 'Egg',
          kcal: 155,
          proteinG: 13,
          carbsG: 1,
          fatG: 11,
          grams: 100,
          count: 0,
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.filter_list));
      await settle(tester);

      expect(find.byType(FbFilterSheet), findsOneWidget);

      // Type in the only TextField in the sheet (the name search field).
      await tester.enterText(find.byType(TextField).first, 'Oat');
      await settle(tester);

      await tester.tap(byIconLabel('Apply'));
      await settle(tester);

      // Sheet is closed; only the matching entry is visible.
      expect(find.byType(FbFilterSheet), findsNothing);
      expect(find.text('Oat'), findsOneWidget);
      expect(find.text('Egg'), findsNothing);
    });
  });

  testWidgets('filter sheet Clear all resets draft then Apply shows all', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await FoodBankService.instance.addManualEntry(
        const FoodBankRecord(
          desc: 'Walnut',
          kcal: 654,
          proteinG: 15,
          carbsG: 14,
          fatG: 65,
          grams: 100,
          count: 0,
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.filter_list));
      await settle(tester);

      await tester.tap(byIconLabel('Clear all'));
      await settle(tester);

      await tester.tap(byIconLabel('Apply'));
      await settle(tester);

      expect(find.text('Walnut'), findsOneWidget);
    });
  });
}
