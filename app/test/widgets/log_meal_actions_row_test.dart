/// The log form's action row, and the delivery button the phone lacked.
///
/// The PC lock screen has had a "🍱 Today's delivery" button since the import
/// shipped; the phone had the queue but no visible control, so standing in
/// the kitchen there was nothing to tap. These tests pin the affordance and
/// the two ways it silently fails: a clipped label, and a dead control on the
/// web build.
library;

import 'package:diet_guard_app/widgets/log_meal_actions_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../label_finders.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    int queued = 0,
    bool busy = false,
    bool canFetch = true,
    Future<void> Function()? onLoad,
    VoidCallback? onLog,
    double width = 360,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: LogMealActionsRow(
              onLoadDelivery: onLoad ?? () async {},
              onLog: onLog ?? () {},
              deliveryBusy: busy,
              dishesQueued: queued,
              canFetchDelivery: canFetch,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('the delivery button is there to tap', (tester) async {
    var taps = 0;
    await pump(tester, onLoad: () async => taps++);

    await tester.tap(find.byIcon(Icons.restaurant));
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets('the queue count is a numeral beside the icon', (tester) async {
    await pump(tester, queued: 4);
    expect(find.text('4'), findsOneWidget);
    expect(byIconLabel("Load today's catering delivery"), findsOneWidget);
  });

  testWidgets('nothing queued shows no numeral and never overflows', (
    tester,
  ) async {
    await pump(tester, width: 300);
    await tester.pumpAndSettle();

    expect(find.text('0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a fetch in flight disables the button and spins', (
    tester,
  ) async {
    await pump(tester, busy: true);

    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('the button stays visible with nothing queued', (tester) async {
    // Never hidden or disabled on an empty queue: the outcome arrives as a
    // cue so a late delivery can still be retried.
    await pump(tester);

    expect(byIconLabel("Load today's catering delivery"), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNotNull);
  });

  testWidgets('web gets no delivery button at all', (tester) async {
    // The desktop target *is* the web build, and the caterer's panel blocks
    // browser requests -- an unguarded button would ship a dead control.
    await pump(tester, canFetch: false);

    expect(find.byIcon(Icons.restaurant), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('the log button still logs', (tester) async {
    var logged = 0;
    await pump(tester, onLog: () => logged++);

    await tester.tap(find.byIcon(Icons.check_circle));
    await tester.pump();

    expect(logged, 1);
  });
}
