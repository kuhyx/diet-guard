/// The "Fill all with catering" row: label per state, Cancel only when armed.
library;

import 'package:diet_guard_app/widgets/fill_all_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
    expect(find.text(fillAllLabel), findsNothing);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('resting: the fill label and no Cancel', (t) async {
    await _pump(t);

    expect(find.text('🍱 Fill all with catering'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('armed: Confirm (N) and a Cancel button', (t) async {
    await _pump(t, armed: 3);

    expect(find.text('✓ Confirm (3)'), findsOneWidget);
    expect(find.text(fillAllLabel), findsNothing);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('busy: Working… and both controls disabled', (t) async {
    var fills = 0;
    var cancels = 0;
    await _pump(
      t,
      busy: true,
      armed: 3,
      onFill: () async => fills++,
      onCancel: () => cancels++,
    );

    expect(find.text('Working…'), findsOneWidget);
    expect(find.text('✓ Confirm (3)'), findsNothing);
    expect(
      t.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    expect(t.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
    await t.tap(find.byType(OutlinedButton), warnIfMissed: false);
    await t.tap(find.byType(TextButton), warnIfMissed: false);
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

    await t.tap(find.text('✓ Confirm (2)'));
    await t.tap(find.text('Cancel'));

    expect([fills, cancels], [1, 1]);
  });
}
