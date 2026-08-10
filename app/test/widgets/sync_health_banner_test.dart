import 'package:diet_guard_app/services/sync_health.dart';
import 'package:diet_guard_app/widgets/sync_health_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pump(WidgetTester tester, SyncHealthStatus? status) =>
    tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SyncHealthBanner(status: status))),
    );

void main() {
  testWidgets('renders nothing before health has been read', (tester) async {
    await pump(tester, null);
    expect(find.byIcon(Icons.cloud_off), findsNothing);
  });

  testWidgets('renders nothing for a healthy device', (tester) async {
    final now = DateTime(2026, 8, 10, 12);
    await pump(
      tester,
      SyncHealthStatus(
        lastSuccess: now.subtract(const Duration(minutes: 5)),
        failureKind: null,
        now: now,
      ),
    );
    expect(find.byIcon(Icons.cloud_off), findsNothing);
  });

  testWidgets('warns when the device has stopped publishing', (tester) async {
    final now = DateTime(2026, 8, 10, 12);
    await pump(
      tester,
      SyncHealthStatus(
        lastSuccess: now.subtract(const Duration(days: 2)),
        failureKind: SyncFailureKind.failed,
        now: now,
      ),
    );

    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    expect(
      find.textContaining('Meals stay on this device'),
      findsOneWidget,
    );
  });

  testWidgets('survives a theme with no AppStatusColors extension', (
    tester,
  ) async {
    // Regression guard: a `!` on the extension lookup crashed every widget
    // test that pumped a bare MaterialApp.
    final now = DateTime(2026, 8, 10, 12);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const []),
        home: Scaffold(
          body: SyncHealthBanner(
            status: SyncHealthStatus(
              lastSuccess: now.subtract(const Duration(days: 2)),
              failureKind: SyncFailureKind.unconfigured,
              now: now,
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
  });
}
