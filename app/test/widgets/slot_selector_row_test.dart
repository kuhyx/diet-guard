import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/widgets/slot_selector_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester, {
  required DateTime now,
  Set<int> loggedSlots = const <int>{},
  int? selectedSlot,
  ValueChanged<int?>? onSlotSelected,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SlotSelectorRow(
        now: now,
        loggedSlots: loggedSlots,
        selectedSlot: selectedSlot,
        onSlotSelected: onSlotSelected ?? (_) {},
      ),
    ),
  ),
);

void main() {
  group('SlotSelectorRow', () {
    testWidgets('renders exactly one chip per day slot', (tester) async {
      await _pump(tester, now: DateTime(2026, 8, 14, 13));

      expect(find.byType(ChoiceChip), findsNWidgets(daySlots().length));
      for (final slot in daySlots()) {
        expect(find.text(slotLabel(slot)), findsOneWidget);
      }
    });

    // The "Snack" chip was removed on 2026-08-14; it was the only control
    // that logged a meal against no slot at all.
    testWidgets('has no Snack chip', (tester) async {
      await _pump(tester, now: DateTime(2026, 8, 14, 13));

      expect(find.text('Snack'), findsNothing);
      expect(find.byIcon(Icons.fastfood), findsNothing);
    });

    testWidgets('tapping a chip reports that slot, never null', (
      tester,
    ) async {
      final selected = <int?>[];
      await _pump(
        tester,
        now: DateTime(2026, 8, 14, 13),
        onSlotSelected: selected.add,
      );

      for (final slot in daySlots()) {
        await tester.tap(find.text(slotLabel(slot)));
      }

      expect(selected, daySlots());
      expect(selected, isNot(contains(null)));
    });

    testWidgets('a logged slot gets a check avatar', (tester) async {
      await _pump(
        tester,
        now: DateTime(2026, 8, 14, 13),
        loggedSlots: {daySlots().first},
      );

      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('marks the selected slot', (tester) async {
      final slot = daySlots().first;
      await _pump(
        tester,
        now: DateTime(2026, 8, 14, 13),
        selectedSlot: slot,
      );

      final chip = tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text(slotLabel(slot)),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(chip.selected, isTrue);
    });
  });
}
