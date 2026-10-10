import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/widgets/meal_schedule_editor.dart';
import 'package:diet_guard_app/widgets/meal_time_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Holds the schedule the way `_SettingsMealSchedule` does: every edit is
/// normalised and fed back, so the preview reflects what would be saved.
class _Harness extends StatefulWidget {
  const _Harness(this.initial, this.edits);

  final MealSchedule initial;
  final List<MealSchedule> edits;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late MealSchedule _schedule = widget.initial;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          MealScheduleEditor(
            schedule: _schedule,
            onChanged: (next) {
              widget.edits.add(next);
              setState(() => _schedule = next.normalized());
            },
          ),
        ],
      ),
    ),
  );
}

const _fiveMeals = MealSchedule(firstMinute: 480, lastMinute: 1200, count: 5);

void main() {
  late List<MealSchedule> edits;

  setUp(() => edits = []);

  Future<void> pump(WidgetTester tester, MealSchedule schedule) async {
    await tester.binding.setSurfaceSize(const Size(500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_Harness(schedule, edits));
  }

  Future<void> openDropdown(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(InputDecorator, label));
    await tester.pumpAndSettle();
  }

  /// Taps [label]'s clock button and types [hh]:[mm] in the time picker's
  /// keyboard mode.
  Future<void> pickExact(
    WidgetTester tester,
    String label,
    String hh,
    String mm,
  ) async {
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is MealTimeDropdown && w.label == label,
        ),
        matching: find.byTooltip('Type or pick an exact time'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), hh);
    await tester.enterText(fields.at(1), mm);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  testWidgets('an off-grid value from another device renders', (tester) async {
    // A dropdown whose value matches no item asserts; a PC-set 07:23 must
    // show as itself rather than take the settings screen down.
    await pump(
      tester,
      const MealSchedule(firstMinute: 443, lastMinute: 1140, count: 5),
    );

    expect(find.text('07:23'), findsWidgets);
    expect(tester.takeException(), isNull);
    await openDropdown(tester, 'First meal');
    expect(find.text('07:23'), findsWidgets);
    expect(find.text('07:15'), findsWidgets);
  });

  testWidgets('choosing a 15-minute value updates the preview', (tester) async {
    await pump(tester, _fiveMeals);
    expect(find.text('08:00  ·  11:00  ·  14:00  ·  17:00  ·  20:00'), findsOne);

    await openDropdown(tester, 'First meal');
    await tester.tap(find.text('07:45').last);
    await tester.pumpAndSettle();

    expect(edits.last.firstMinute, 465);
    expect(find.text('07:45  ·  10:45  ·  14:00  ·  17:00  ·  20:00'), findsOne);
  });

  testWidgets('the clock button opens the time picker and applies 07:23', (
    tester,
  ) async {
    await pump(tester, _fiveMeals);

    await pickExact(tester, 'First meal', '07', '23');

    expect(edits.last.firstMinute, 443);
    expect(edits.last.lastMinute, 1200);
    expect(find.text('07:23'), findsWidgets);
  });

  testWidgets('no "Custom…" item remains in either menu', (tester) async {
    await pump(tester, _fiveMeals);

    for (final dropdown in tester.widgetList<DropdownButton<int>>(
      find.byType(DropdownButton<int>),
    )) {
      final values = [for (final item in dropdown.items!) item.value!];
      expect(values.every((v) => v >= 0), isTrue, reason: 'no sentinel');
    }
    await openDropdown(tester, 'First meal');
    await tester.scrollUntilVisible(
      find.text('00:00'),
      -300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Custom…'), findsNothing);
  });

  testWidgets('an exact last meal before the first is clamped', (tester) async {
    await pump(tester, _fiveMeals);

    await pickExact(tester, 'Last meal', '06', '00');

    // One grid step after 08:00: the shortest legal window, not a rejection.
    expect(edits.last.lastMinute, 495);
  });

  testWidgets('Last meal only offers times after the first', (tester) async {
    await pump(tester, _fiveMeals);

    MealTimeDropdown field(String label) => tester.widget(
      find.byWidgetPredicate((w) => w is MealTimeDropdown && w.label == label),
    );
    final last = field('Last meal').options;
    expect(last.first, 495, reason: '08:15, one grid step after 08:00');
    expect(last.last, 1425, reason: '23:45, the last grid mark');
    final first = field('First meal').options;
    expect(first.first, 0);
    expect(first.last, 1410, reason: '23:30 leaves a grid-aligned last meal');
    expect(first.every((m) => m % 15 == 0), isTrue);
  });

  testWidgets('meal counts shrink to what a narrow window holds', (
    tester,
  ) async {
    const narrow = MealSchedule(firstMinute: 480, lastMinute: 510, count: 2);
    expect(
      const MealScheduleEditor(schedule: narrow, onChanged: _ignore)
          .selectableCounts,
      [2, 3],
    );
    expect(
      const MealScheduleEditor(schedule: _fiveMeals, onChanged: _ignore)
          .selectableCounts,
      [2, 3, 4, 5, 6],
    );

    await pump(tester, narrow);
    await openDropdown(tester, 'Meals per day');
    expect(find.text('3'), findsWidgets);
    expect(find.text('4'), findsNothing);
  });
}

void _ignore(MealSchedule _) {}
