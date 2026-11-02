import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/widgets/food_bank/fb_tile_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<FoodBankRecord> _foods(int n, {double count = 0}) => [
  for (var i = 0; i < n; i++)
    FoodBankRecord(
      desc: 'Food $i',
      kcal: 100,
      proteinG: 1,
      carbsG: 2,
      fatG: 3,
      grams: 100,
      count: count,
    ),
];

Future<void> _pump(
  WidgetTester tester,
  List<FoodBankRecord> records, {
  ValueChanged<FoodBankRecord>? onOpen,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: FbTileGrid(records: records, onOpen: onOpen ?? (_) {}),
    ),
  ),
);

void main() {
  test('rows never drop below one, even in a tiny box', () {
    expect(fbRowsFor(10), 1);
    expect(fbRowsFor(600), greaterThan(3));
  });

  testWidgets('a short list is one page: partial row, no dots, no count', (
    tester,
  ) async {
    FoodBankRecord? opened;
    await _pump(tester, _foods(4), onOpen: (r) => opened = r);
    expect(find.text('Food 3'), findsOneWidget);
    expect(find.textContaining('×'), findsNothing);
    expect(find.byType(PageView), findsOneWidget);
    await tester.tap(find.text('Food 3'));
    expect(opened?.desc, 'Food 3');
  });

  testWidgets('used foods show their count', (tester) async {
    await _pump(tester, _foods(2, count: 7));
    expect(find.text('×7'), findsNWidgets(2));
  });

  testWidgets('many pages show a sliding window of dots', (tester) async {
    await _pump(tester, _foods(400));
    final dots = find.descendant(
      of: find.byType(ExcludeSemantics),
      matching: find.byType(Container),
    );
    expect(dots, findsNWidgets(7));
    await tester.fling(find.byType(PageView), const Offset(-600, 0), 3000);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(PageView), const Offset(-600, 0), 3000);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(PageView), const Offset(-600, 0), 3000);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(PageView), const Offset(-600, 0), 3000);
    await tester.pumpAndSettle();
    expect(dots, findsNWidgets(7));
  });

  testWidgets('shrinking the list while on a late page stays in range', (
    tester,
  ) async {
    await _pump(tester, _foods(400));
    for (var i = 0; i < 3; i++) {
      await tester.fling(find.byType(PageView), const Offset(-600, 0), 3000);
      await tester.pumpAndSettle();
    }
    await _pump(tester, _foods(5));
    await tester.pumpAndSettle();
    expect(find.text('Food 0'), findsOneWidget);
  });
}
