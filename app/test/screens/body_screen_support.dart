// Shared setup for the Body screen test files (split for the 250-line cap).

import 'dart:convert';

import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/screens/body_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../services/body_test_support.dart';

export '../services/body_test_support.dart';

/// Points every service the screen reads at [store]; returns a teardown.
Future<void> setUpBodyServices(MemoryDocStore store) async {
  LogStorageService.resetForTesting(store: store);
  AppSettingsService.resetForTesting(store: store);
  await BodyService.initForTesting(store);
}

/// Undoes [setUpBodyServices].
void tearDownBodyServices() {
  BodyService.resetForTesting();
  LogStorageService.resetForTesting();
  AppSettingsService.resetForTesting();
}

/// Pumps the Body screen on a view tall enough to lay out every card.
Future<void> pumpBody(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 12000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: BodyScreen()));
  await tester.pumpAndSettle();
}

/// Yesterday's local date key.
String yesterdayKey() =>
    localDateKey(DateTime.now().subtract(const Duration(days: 1)));

/// An 80 kg, 180 cm, 30-year-old man with a run, a lift and 9000 steps
/// yesterday; optionally a saved [goal].
Future<void> seedPerson(MemoryDocStore store, {Object? goal}) async {
  final today = DateTime.now();
  const t = '2026-09-01T10:00:00+02:00';
  store.documents[BodyService.documentName] = jsonEncode({
    'profile': {
      'birth': {'v': localDateKey(DateTime(today.year - 30, 1, 1)), 't': t},
      'height_cm': {'v': 180, 't': t},
      'sex': {'v': 'm', 't': t},
      if (goal != null) 'goal': {'v': goal, 't': t},
    },
    'weights': {
      '2026-09-20': {'kg': 81, 'src': 'phone', 't': '2026-09-20T07:00:00Z'},
      yesterdayKey(): {'kg': 80, 'src': 'manual', 't': '2026-09-20T07:00:00Z'},
    },
    'steps': {
      yesterdayKey(): {'n': 9000, 't': t},
    },
    'activity': {
      't': t,
      'sessions': [
        {
          'day': yesterdayKey(),
          'kind': 'run',
          'min': 60,
          'km': 10,
          'label': 'Evening run',
          'src': 'runnerup',
        },
        {
          'day': yesterdayKey(),
          'kind': 'strength',
          'min': 80,
          'label': 'StrongLifts A',
          'src': 'screen-locker',
        },
      ],
    },
  });
  await BodyService.initForTesting(store);
}

/// The top edge of [finder]'s first match.
double topOf(WidgetTester tester, Finder finder) =>
    tester.getTopLeft(finder.first).dy;
