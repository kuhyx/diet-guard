import 'dart:convert';
import 'dart:io';

import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/screens/settings_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:permission_handler/permission_handler.dart';
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
    tempDir = await Directory.systemTemp.createTemp('diet_guard_settings_');
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
    FoodBankService.resetForTesting(store: FileDocumentStore(tempDir));
    AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  // SettingsScreen loads its settings via a fire-and-forget Future in
  // initState that Flutter's frame scheduler does not track -- same pitfall
  // as HistoryScreen/LogMealScreen. Also grows the test viewport: the
  // Notifications section pushes earlier fields/buttons below the default
  // 800x600 fold, making them unreachable to tester.tap otherwise.
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

  testWidgets('shows the kuhyx/syncs defaults on a fresh install', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      expect(find.widgetWithText(TextField, 'kuhyx'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'syncs'), findsOneWidget);
    });
  });

  testWidgets('loads existing saved reward values into their fields', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await AppSettingsService.instance.saveReward(
        label: 'Podcast',
        url: 'https://example.com/podcast',
      );

      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      expect(find.widgetWithText(TextField, 'Podcast'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'https://example.com/podcast'),
        findsOneWidget,
      );
    });
  });

  testWidgets('typing into the reward fields persists them', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      await tester.enterText(
        find.widgetWithText(TextField, 'Reward label'),
        'Podcast',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Reward URL'),
        'https://example.com/podcast',
      );
      await settle(tester);

      expect(AppSettingsService.rewardLabel, 'Podcast');
      expect(AppSettingsService.rewardUrl, 'https://example.com/podcast');
    });
  });

  testWidgets('Save persists the entered token', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
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
        MaterialApp(home: SettingsScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Test connection'));
      await settle(tester);

      expect(find.text('Connection OK.'), findsOneWidget);
    });
  });

  testWidgets('Test connection reports failure', (tester) async {
    final mock = MockClient((_) async => http.Response('', 403));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Test connection'));
      await settle(tester);

      expect(find.text('Connection failed.'), findsOneWidget);
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
        MaterialApp(home: SettingsScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Sync now'));
      await settle(tester);

      expect(find.text('Synced.'), findsOneWidget);
    });
  });

  testWidgets('Test connection reports a network exception', (tester) async {
    final mock = MockClient((_) async => throw const FormatException('no net'));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Test connection'));
      await settle(tester);

      expect(find.textContaining('Connection failed:'), findsOneWidget);
    });
  });

  testWidgets('Sync now reports a GitHub error', (tester) async {
    final mock = MockClient((_) async => http.Response('boom', 500));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(httpClient: mock)),
      );
      await settle(tester);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Sync now'));
      await settle(tester);

      expect(find.textContaining('Sync failed:'), findsOneWidget);
    });
  });

  testWidgets('shows the Connect GitHub button', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      expect(find.text('Connect GitHub'), findsOneWidget);
    });
  });

  /// Expands "Advanced" and types [clientId] into the client-id field.
  Future<void> enterClientId(WidgetTester tester, String clientId) async {
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'OAuth App client id'),
      clientId,
    );
  }

  testWidgets('Connect GitHub without a client id opens setup guidance', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);
      await enterClientId(tester, '');

      await tester.tap(find.text('Connect GitHub'));
      await settle(tester);

      expect(find.text('One-time GitHub setup needed'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Client ID'), findsOneWidget);
    });
  });

  testWidgets('cancelling the client id setup dialog aborts the connect', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);
      await enterClientId(tester, '');

      await tester.tap(find.text('Connect GitHub'));
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);

      expect(find.text('One-time GitHub setup needed'), findsNothing);
    });
  });

  testWidgets(
    'entering a client id in the setup dialog saves it and proceeds',
    (tester) async {
      final mock = MockClient((_) async => http.Response('nope', 422));
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(home: SettingsScreen(httpClient: mock)),
        );
        await settle(tester);
        await enterClientId(tester, '');

        await tester.tap(find.text('Connect GitHub'));
        await settle(tester);
        await tester.enterText(
          find.widgetWithText(TextField, 'Client ID'),
          'cid',
        );
        await tester.tap(find.text('Continue'));
        await settle(tester);

        expect(
          find.textContaining('Could not start device flow'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(TextField, 'OAuth App client id'),
          findsOneWidget,
        );
        expect(
          (tester.widget(
                    find.widgetWithText(TextField, 'OAuth App client id'),
                  )
                  as TextField)
              .controller!
              .text,
          'cid',
        );
      });
    },
  );

  testWidgets('device flow failure to start shows a message', (tester) async {
    final mock = MockClient((_) async => http.Response('nope', 422));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(httpClient: mock)),
      );
      await settle(tester);
      await enterClientId(tester, 'cid');

      await tester.tap(find.text('Connect GitHub'));
      await settle(tester);

      expect(
        find.textContaining('Could not start device flow'),
        findsOneWidget,
      );
    });
  });

  testWidgets('device flow happy path saves the token and syncs', (
    tester,
  ) async {
    final mock = MockClient((req) async {
      if (req.url.path.contains('device/code')) {
        return http.Response(
          jsonEncode({
            'device_code': 'dev123',
            'user_code': 'WXYZ-1234',
            'verification_uri': 'https://github.com/login/device',
            'interval': 0,
            'expires_in': 900,
          }),
          200,
        );
      }
      if (req.url.path.contains('login/oauth/access_token')) {
        return http.Response(jsonEncode({'access_token': 'gho_test'}), 200);
      }
      if (req.method == 'PUT') return http.Response('{}', 200);
      // A bare `/repos/<owner>/<repo>` GET is crdt_sync's GitHubClient
      // probing whether the repo itself exists (vs. a content path just
      // being unused) -- must succeed so an empty repo isn't mistaken for
      // a missing one.
      if (req.method == 'GET' && req.url.pathSegments.length == 3) {
        return http.Response('{}', 200);
      }
      return http.Response('', 404); // sync's pull-side list/read calls
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(httpClient: mock)),
      );
      await settle(tester);
      await enterClientId(tester, 'cid');

      await tester.tap(find.text('Connect GitHub'));
      await pumpUntil(
        tester,
        () => find.text('WXYZ-1234').evaluate().isNotEmpty,
      );
      expect(find.text('WXYZ-1234'), findsOneWidget);

      // Let the dialog poll (interval 0) and resolve the token, then the
      // post-connect sync runs against the mock.
      await pumpUntil(
        tester,
        () => find.textContaining('Connected and synced').evaluate().isNotEmpty,
      );

      expect(find.textContaining('Connected and synced'), findsOneWidget);
    });
  });

  testWidgets(
    'device flow connects but surfaces a post-connect sync failure',
    (tester) async {
      final mock = MockClient((req) async {
        if (req.url.path.contains('device/code')) {
          return http.Response(
            jsonEncode({
              'device_code': 'dev123',
              'user_code': 'WXYZ-1234',
              'verification_uri': 'https://github.com/login/device',
              'interval': 0,
              'expires_in': 900,
            }),
            200,
          );
        }
        if (req.url.path.contains('login/oauth/access_token')) {
          return http.Response(jsonEncode({'access_token': 'gho_test'}), 200);
        }
        return http.Response('boom', 500); // the sync's repo calls fail
      });

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(home: SettingsScreen(httpClient: mock)),
        );
        await settle(tester);
        await enterClientId(tester, 'cid');

        await tester.tap(find.text('Connect GitHub'));
        await pumpUntil(
          tester,
          () => find.textContaining('sync failed').evaluate().isNotEmpty,
        );

        expect(find.textContaining('sync failed'), findsOneWidget);
      });
    },
  );

  testWidgets('device dialog: failed poll shows the error and Open launches', (
    tester,
  ) async {
    final launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;

    // The dialog's Open button copies the code to the clipboard first;
    // there's no clipboard plugin in the test host, so stub the channel.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final mock = MockClient((req) async {
      if (req.url.path.contains('device/code')) {
        return http.Response(
          jsonEncode({
            'device_code': 'dev123',
            'user_code': 'WXYZ-1234',
            'verification_uri': 'https://github.com/login/device',
            'interval': 0,
            'expires_in': 900,
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({'error': 'access_denied', 'error_description': 'no'}),
        200,
      );
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(httpClient: mock)),
      );
      await settle(tester);
      await enterClientId(tester, 'cid');

      await tester.tap(find.text('Connect GitHub'));
      await pumpUntil(
        tester,
        () => find.text('WXYZ-1234').evaluate().isNotEmpty,
      );
      expect(find.text('WXYZ-1234'), findsOneWidget);

      await pumpUntil(
        tester,
        () => find.textContaining('access_denied').evaluate().isNotEmpty,
      );

      expect(find.textContaining('access_denied'), findsOneWidget);

      await tester.tap(find.text('Open GitHub & copy code'));
      await tester.pump();
      expect(launcher.launched, 'https://github.com/login/device');

      await tester.tap(find.text('Cancel'));
      await settle(tester);
    });
  });

  testWidgets('battery exemption button reports a granted status', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            requestBatteryExemption: () async => PermissionStatus.granted,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('Disable battery optimization'));
      await settle(tester);

      expect(find.textContaining('exemption granted'), findsOneWidget);
    });
  });

  testWidgets('battery exemption button reports a denied status', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            requestBatteryExemption: () async => PermissionStatus.denied,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('Disable battery optimization'));
      await settle(tester);

      expect(find.textContaining('not granted'), findsOneWidget);
    });
  });

  testWidgets('battery exemption defaults to the real permission_handler '
      'call, which fails predictably under test', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await settle(tester);

      await tester.tap(find.text('Disable battery optimization'));
      await settle(tester);

      expect(
        find.textContaining('Could not request exemption'),
        findsOneWidget,
      );
    });
  });

  testWidgets('battery exemption button surfaces a request failure', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            requestBatteryExemption: () async =>
                throw Exception('no permission service'),
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('Disable battery optimization'));
      await settle(tester);

      expect(
        find.textContaining('Could not request exemption'),
        findsOneWidget,
      );
    });
  });
}
