// Shared helpers for the picker widget tests: open a dialog from a button and
// read back what it popped, and find cells by state rather than by text.

import 'package:diet_guard_app/widgets/pickers/numeral_cell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../label_finders.dart';

/// What a dialog popped: [closed] turns true once it is gone.
class Popped {
  /// The popped value (null when cancelled).
  Object? value;

  /// Whether the dialog has closed.
  bool closed = false;
}

/// Pumps an app whose one button opens [dialog]; taps it and settles.
Future<Popped> openDialog(
  WidgetTester tester,
  Widget dialog, {
  Size size = const Size(500, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final popped = Popped();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.add, semanticLabel: 'open'),
            onPressed: () async {
              popped
                ..value = await showDialog<Object>(
                  context: context,
                  builder: (_) => dialog,
                )
                ..closed = true;
            },
          ),
        ),
      ),
    ),
  );
  await tester.tap(byIconLabel('open'));
  await tester.pumpAndSettle();
  return popped;
}

/// The cell keyed [key] (a `DateTime` day, or `'month-<m>'`).
NumeralCell cell(WidgetTester tester, Object key) => tester.widget<NumeralCell>(
  find.byKey(
    key is DateTime ? ValueKey<DateTime>(key) : ValueKey<String>('$key'),
  ),
);

/// The check button, enabled or not.
IconButton confirmButton(WidgetTester tester) => tester.widget<IconButton>(
  find.ancestor(of: byIconLabel('Confirm'), matching: find.byType(IconButton)),
);

/// Scrolls the open time dialog's wheels to [hour] and [minute] (a disabled
/// value springs back) and settles. Does not confirm.
Future<void> setWheels(WidgetTester tester, int hour, int minute) async {
  for (final (key, value) in [('hour', hour), ('minute', minute)]) {
    final wheel = tester.widget<ListWheelScrollView>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(ListWheelScrollView),
      ),
    );
    (wheel.controller! as FixedExtentScrollController).jumpToItem(value);
    await tester.pumpAndSettle();
  }
}

/// Taps the check and settles.
Future<void> confirm(WidgetTester tester) async {
  await tester.tap(controlByLabel('Confirm'));
  await tester.pumpAndSettle();
}
