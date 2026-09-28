import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/health_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'body_screen_support.dart';
import '../services/health_steps_test.dart' show FakeStepsSource;

void main() {
  final original = stepsSource;
  late MemoryDocStore store;

  setUp(() async {
    store = MemoryDocStore();
    await setUpBodyServices(store);
  });

  tearDown(() {
    stepsSource = original;
    tearDownBodyServices();
  });

  testWidgets('connect asks once; granted reads steps and hides it', (
    tester,
  ) async {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final fake = FakeStepsSource(
      granted: false,
      intervals: [
        StepInterval(yesterday, yesterday.add(const Duration(hours: 1)), 6500),
      ],
    )..grantOnRequest = false;
    stepsSource = fake;
    await pumpBody(tester);
    expect(fake.lastRead, isNull, reason: 'never reads before permission');

    await tester.tap(find.text('Connect Health Connect steps'));
    await tester.pumpAndSettle();
    expect(find.text('Connect Health Connect steps'), findsOneWidget);

    fake.grantOnRequest = true;
    await tester.tap(find.text('Connect Health Connect steps'));
    await tester.pumpAndSettle();
    expect(find.text('Connect Health Connect steps'), findsNothing);
    expect(
      BodyService.instance.document.steps[localDateKey(yesterday)]!.n,
      6500,
    );
  });

  testWidgets('already granted: refreshes on open, no button', (tester) async {
    final fake = FakeStepsSource();
    stepsSource = fake;
    await pumpBody(tester);
    expect(fake.lastRead, isNotNull);
    expect(find.text('Connect Health Connect steps'), findsNothing);
  });

  testWidgets('a Health Connect error just hides nothing', (tester) async {
    stepsSource = FakeStepsSource()..failWith = StateError('gone');
    await pumpBody(tester);
    expect(find.text('Connect Health Connect steps'), findsOneWidget);
  });
}
