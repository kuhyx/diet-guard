// The Body screen's two date controls apply what their picker confirms:
// the dated-value card's day, and the profile's birth date (whose picker
// opens with the year wheel focused).

import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/widgets/body/dated_value_card.dart';
import 'package:diet_guard_app/widgets/body/profile_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../label_finders.dart';
import '../screens/body_screen_support.dart';

Future<void> _host(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

Future<void> _pressAndSettle(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the dated-value card shows the confirmed day', (tester) async {
    await _host(
      tester,
      DatedValueCard(
        semanticLabel: 'Weight',
        fieldSemanticLabel: 'Weight (kg)',
        icon: Icons.monitor_weight,
        unit: 'kg',
        min: 20,
        max: 400,
        latest: null,
        series: const [],
        onSave: (_, _) async {},
        onDelete: (_) async {},
        onChanged: () {},
      ),
    );
    final now = DateTime.now();
    final yesterday = localDateKey(DateTime(now.year, now.month, now.day - 1));
    await tester.tap(find.byIcon(Icons.event));
    await tester.pumpAndSettle();
    await _pressAndSettle(tester, LogicalKeyboardKey.arrowLeft);
    await _pressAndSettle(tester, LogicalKeyboardKey.enter);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text(' $yesterday'), findsOneWidget);
  });

  testWidgets('the birth date opens on the year wheel and applies', (
    tester,
  ) async {
    await setUpBodyServices(MemoryDocStore());
    addTearDown(tearDownBodyServices);
    await _host(tester, ProfileCard(onSaved: () {}));
    final year = DateTime.now().year - 31;
    await tester.tap(byIconLabel('Birth date'));
    await tester.pumpAndSettle();
    await _pressAndSettle(tester, LogicalKeyboardKey.arrowUp);
    await _pressAndSettle(tester, LogicalKeyboardKey.enter);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text(' $year-01-01'), findsOneWidget);
  });
}
