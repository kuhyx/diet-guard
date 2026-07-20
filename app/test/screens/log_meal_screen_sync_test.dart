// Covers LogMealScreen's auto-sync: triggered on launch and on every
// AppLifecycleState change, best-effort/silent regardless of outcome.

import 'dart:io';

import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_secure_storage.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_autosync_');
    LogStorageService.resetForTesting(testDir: tempDir);
    FoodBankService.resetForTesting(testDir: tempDir);
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'does not push when sync is unconfigured (defaults to off)',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      installFakeSecureStorage();
      var puts = 0;
      final mock = MockClient((req) async {
        if (req.method == 'PUT') puts++;
        return http.Response('', 404);
      });

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(home: LogMealScreen(httpClient: mock)),
        );
        await settle(tester);

        expect(puts, 0);
      });
    },
  );

  testWidgets('pushes on launch when sync is configured', (tester) async {
    SharedPreferences.setMockInitialValues({
      'sync.owner': 'o',
      'sync.repo': 'r',
    });
    installFakeSecureStorage(initial: {'sync.token': 't'});
    var puts = 0;
    final mock = MockClient((req) async {
      if (req.method == 'PUT') puts++;
      // A bare `/repos/<owner>/<repo>` GET is crdt_sync's GitHubClient
      // probing whether the repo itself exists (vs. a content path just
      // being unused) -- must succeed so an empty/unconfigured repo isn't
      // mistaken for a missing one.
      if (req.method == 'GET' && req.url.pathSegments.length == 3) {
        return http.Response('{}', 200);
      }
      return http.Response('', 404);
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: LogMealScreen(httpClient: mock)),
      );
      await settle(tester);

      expect(puts, 1);
    });
  });

  testWidgets('pushes again when the app is paused', (tester) async {
    SharedPreferences.setMockInitialValues({
      'sync.owner': 'o',
      'sync.repo': 'r',
    });
    installFakeSecureStorage(initial: {'sync.token': 't'});
    var puts = 0;
    final mock = MockClient((req) async {
      if (req.method == 'PUT') puts++;
      // A bare `/repos/<owner>/<repo>` GET is crdt_sync's GitHubClient
      // probing whether the repo itself exists (vs. a content path just
      // being unused) -- must succeed so an empty/unconfigured repo isn't
      // mistaken for a missing one.
      if (req.method == 'GET' && req.url.pathSegments.length == 3) {
        return http.Response('{}', 200);
      }
      return http.Response('', 404);
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: LogMealScreen(httpClient: mock)),
      );
      await settle(tester);
      expect(puts, 1); // launch

      // Flutter's AppLifecycleListener enforces a strict transition graph
      // (resumed -> inactive -> hidden -> paused -> ...); jumping straight
      // from resumed to paused is the one direct transition it allows.
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await settle(tester);
      expect(puts, 2);
    });
  });

  testWidgets('swallows a sync failure without crashing the screen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'sync.owner': 'o',
      'sync.repo': 'r',
    });
    installFakeSecureStorage(initial: {'sync.token': 't'});
    final mock = MockClient((_) async => http.Response('boom', 500));

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: LogMealScreen(httpClient: mock)),
      );
      await settle(tester);

      expect(find.byType(LogMealScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('pushes immediately after a meal is logged', (tester) async {
    SharedPreferences.setMockInitialValues({
      'sync.owner': 'o',
      'sync.repo': 'r',
    });
    installFakeSecureStorage(initial: {'sync.token': 't'});
    var puts = 0;
    final mock = MockClient((req) async {
      if (req.method == 'PUT') puts++;
      if (req.method == 'GET' && req.url.pathSegments.length == 3) {
        return http.Response('{}', 200);
      }
      return http.Response('', 404);
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: LogMealScreen(httpClient: mock)),
      );
      await settle(tester);
      expect(puts, 1); // launch push

      await tester.enterText(find.byType(TextField).at(0), 'push-on-log');
      await tester.pump();
      await tester.tap(find.byTooltip('Log meal'));
      await settle(tester);

      // The new meal is pushed right away, not left for a lifecycle event.
      expect(puts, 2);
    });
  });

  testWidgets('pushes immediately after repeating the last meal', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'sync.owner': 'o',
      'sync.repo': 'r',
    });
    installFakeSecureStorage(initial: {'sync.token': 't'});
    var puts = 0;
    final mock = MockClient((req) async {
      if (req.method == 'PUT') puts++;
      if (req.method == 'GET' && req.url.pathSegments.length == 3) {
        return http.Response('{}', 200);
      }
      return http.Response('', 404);
    });

    await tester.runAsync(() async {
      await LogStorageService.instance.logMeal(
        'seed meal',
        const Nutrition(
          kcal: 100,
          proteinG: 5,
          carbsG: 10,
          fatG: 2,
          grams: 50,
          source: 'manual',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(home: LogMealScreen(httpClient: mock)),
      );
      await settle(tester);
      expect(puts, 1); // launch push

      final fab = find.byType(FloatingActionButton);
      await tester.ensureVisible(fab);
      await tester.tap(fab);
      await settle(tester);

      // The repeated meal is pushed right away too, same as manual logging.
      expect(puts, 2);
    });
  });
}
