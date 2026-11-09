/// The "Fill all with catering" row: glyph per state, Cancel only when armed.
library;

import 'package:diet_guard_app/widgets/fill_all_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'label_finders.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool canFetch = true,
  bool busy = false,
  int armed = 0,
  Future<void> Function()? onFill,
  VoidCallback? onCancel,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: FillAllRow(
        onFill: onFill ?? () async {},
        onCancel: onCancel ?? () {},
        busy: busy,
        armedCount: armed,
        canFetchDelivery: canFetch,
      ),
    ),
  ),
);

void main() {
  testWidgets('is hidden where delivery cannot be fetched (web)', (t) async {
    await _pump(t, canFetch: false, armed: 3);

    expect(find.byType(OutlinedButton), findsNothing);
    expect(byIconLabel(fillAllLabel), findsNothing);
    expect(byIconLabel('Cancel'), findsNothing);
  });

  testWidgets('resting: the fill glyph and no Cancel', (t) async {
    await _pump(t);

    expect(byIconLabel(fillAllLabel), findsOneWidget);
    expect(find.byIcon(Icons.playlist_add_check), findsOneWidget);
    expect(byIconLabel('Cancel'), findsNothing);
  });

  testWidgets('armed: double check with the count, and a Cancel button', (
    t,
  ) async {
    await _pump(t, armed: 3);

    expect(byIconLabel('Confirm'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(byIconLabel(fillAllLabel), findsNothing);
    expect(byIconLabel('Cancel'), findsOneWidget);
  });

  testWidgets('busy: spinner and both controls disabled', (t) async {
    var fills = 0;
    var cancels = 0;
    await _pump(
      t,
      busy: true,
      armed: 3,
      onFill: () async => fills++,
      onCancel: () => cancels++,
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(byIconLabel('Confirm'), findsNothing);
    expect(
      t.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    expect(t.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
    await t.tap(find.byType(OutlinedButton), warnIfMissed: false);
    await t.tap(find.byType(IconButton), warnIfMissed: false);
    expect(fills + cancels, 0);
  });

  testWidgets('taps reach the callbacks when idle', (t) async {
    var fills = 0;
    var cancels = 0;
    await _pump(
      t,
      armed: 2,
      onFill: () async => fills++,
      onCancel: () => cancels++,
    );

    await t.tap(byIconLabel('Confirm'));
    await t.tap(byIconLabel('Cancel'));

    expect([fills, cancels], [1, 1]);
  });
}
