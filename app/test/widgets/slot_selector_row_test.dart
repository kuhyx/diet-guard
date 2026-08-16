import 'package:diet_guard_app/models/meal_schedule.dart';
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

      expect(
        find.byType(ChoiceChip),
        findsNWidgets(daySlots(kDefaultSchedule).length),
      );
      for (final slot in daySlots(kDefaultSchedule)) {
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

      for (final slot in daySlots(kDefaultSchedule)) {
        await tester.tap(find.text(slotLabel(slot)));
      }

      expect(selected, daySlots(kDefaultSchedule));
      expect(selected, isNot(contains(null)));
    });

    testWidgets('a logged slot gets a check avatar', (tester) async {
      await _pump(
        tester,
        now: DateTime(2026, 8, 14, 13),
        loggedSlots: {daySlots(kDefaultSchedule).first},
      );

      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('marks the selected slot', (tester) async {
      final slot = daySlots(kDefaultSchedule).first;
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

    // The row used to be a Wrap, which pushed the later pills onto a second
    // line: a logged chip is ~124px at Material defaults, so even four need
    // more width than a phone has. Both halves below matter -- a Row of
    // Expanded children also passes the "one line" check while squeezing each
    // label to ~10px (about one character) and throwing nothing at all.
    testWidgets('keeps every chip on one legible row at phone widths', (
      tester,
    ) async {
      for (final width in <double>[320, 360, 412]) {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        // Every slot logged is the widest case: each chip carries a check
        // avatar on top of its label.
        await _pump(
          tester,
          now: DateTime(2026, 8, 14, 21),
          loggedSlots: daySlots(kDefaultSchedule).toSet(),
        );

        expect(tester.takeException(), isNull, reason: 'overflowed at $width');

        final labels = daySlots(
          kDefaultSchedule,
        ).map((slot) => tester.getRect(find.text(slotLabel(slot)))).toList();
        for (final label in labels) {
          expect(
            label.top,
            moreOrLessEquals(labels.first.top, epsilon: 0.5),
            reason: 'chip wrapped to a second line at $width',
          );
          expect(
            label.width,
            greaterThan(20),
            reason: 'label squeezed to ${label.width}px at $width',
          );
        }
      }
    });
  });
}
