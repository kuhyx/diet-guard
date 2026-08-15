import 'dart:io';

import 'package:diet_guard_app/screens/github_mirror_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_health.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../fake_secure_storage.dart';

/// Stub launcher that records the URL instead of opening it, so the device
/// dialog's "Open GitHub & copy code" can be exercised without a real
/// platform channel.
class _FakeUrlLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  String? launched;

  @override
  final LinkDelegate? linkDelegate = null;

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched = url;
    return true;
  }
}

void main() {

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_github_');
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
    FoodBankService.resetForTesting(store: FileDocumentStore(tempDir));
    AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
    BudgetHistoryService.resetForTesting(
      store: FileDocumentStore(tempDir),
    );
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  // GitHubMirrorScreen loads its settings via a fire-and-forget Future in
  // initState that Flutter's frame scheduler does not track -- same pitfall
  // as HistoryScreen/LogMealScreen.
  Future<void> settle(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  /// Drains the device flow's real `Future.delayed` poll (GitHubDeviceAuth
  /// injects no test delay, so under `runAsync` it is a genuine Timer, not
  /// the fake-clock one `tester.pump(duration)` advances) by interleaving
  /// real waits with frame pumps until [done] is true or [maxTries] is hit.
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() done, {
    int maxTries = 200,
  }) async {
    for (var i = 0; i < maxTries && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  }


  /// Types [clientId] into the client-id field.
  Future<void> enterClientId(WidgetTester tester, String clientId) async {
    await tester.enterText(
      find.widgetWithText(TextField, 'OAuth App client id'),
      clientId,
    );
  }

  testWidgets('shows the kuhyx/syncs defaults on a fresh install', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: GitHubMirrorScreen()));
      await settle(tester);

      expect(find.widgetWithText(TextField, 'kuhyx'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'syncs'), findsOneWidget);
    });
  });
  testWidgets('Save persists the entered token', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: GitHubMirrorScreen()));
      await settle(tester);

      await tester.enterText(
        find.widgetWithText(TextField, 'Personal access token (fallback)'),
        'my-pat',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await settle(tester);

      expect(find.text('Saved.'), findsOneWidget);
    });
  });
  testWidgets('Test connection reports success', (tester) async {
    final mock = MockClient(
      (_) async => http.Response('{}', 200),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: GitHubMirrorScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Test GitHub connection'),
      );
      await settle(tester);

      expect(find.text('GitHub connection OK.'), findsOneWidget);
    });
  });
  testWidgets('Test connection reports failure', (tester) async {
    final mock = MockClient((_) async => http.Response('', 403));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: GitHubMirrorScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Test GitHub connection'),
      );
      await settle(tester);

      expect(find.text('GitHub connection failed.'), findsOneWidget);
    });
  });
  testWidgets('Sync now runs a sync tick and reports success', (
    tester,
  ) async {
    final mock = MockClient((req) async {
      if (req.method == 'PUT') return http.Response('{}', 200);
      // A bare `/repos/<owner>/<repo>` GET is crdt_sync's GitHubClient
      // probing whether the repo itself exists (vs. a content path just
      // being unused) -- must succeed so an empty repo isn't mistaken for
      // a missing one.
      if (req.method == 'GET' && req.url.pathSegments.length == 3) {
        return http.Response('{}', 200);
      }
      return http.Response('', 404);
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: GitHubMirrorScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Sync now'));
      await settle(tester);

      expect(find.text('Synced.'), findsOneWidget);
    });
  });
  testWidgets('Sync now clears a stored failure so the banner lifts', (
    tester,
  ) async {
    // "Sync now" is the button a user reaches *because* the log screen's
    // banner told them syncing had stopped. If a successful run here left
    // the recorded failure in place, the recovery action would not dismiss
    // the warning it caused, and the banner would keep accusing a device
    // that is now publishing fine.
    await SyncHealth.recordFailure();
    expect((await SyncHealth.read()).failureKind, SyncFailureKind.failed);

    final mock = MockClient((req) async {
      if (req.method == 'PUT') return http.Response('{}', 200);
      if (req.method == 'GET' && req.url.pathSegments.length == 3) {
        return http.Response('{}', 200);
      }
      return http.Response('', 404);
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: GitHubMirrorScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Sync now'));
      await settle(tester);

      expect(find.text('Synced.'), findsOneWidget);
      final status = await SyncHealth.read();
      expect(status.failureKind, isNull);
      expect(status.isStalled, isFalse);
    });
  });
  testWidgets('Test connection reports a network exception', (tester) async {
    final mock = MockClient((_) async => throw const FormatException('no net'));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: GitHubMirrorScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Test GitHub connection'),
      );
      await settle(tester);

      expect(find.textContaining('GitHub connection failed:'), findsOneWidget);
    });
  });
  testWidgets('Sync now reports a GitHub error', (tester) async {
    final mock = MockClient((_) async => http.Response('boom', 500));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: GitHubMirrorScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Sync now'));
      await settle(tester);

      expect(find.textContaining('Sync failed:'), findsOneWidget);
    });
  });
}
