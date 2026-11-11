// Guard: every date, date-range and time picker the app opens paints no
// words -- only numerals and punctuation. Each picker is opened through its
// real call site, so a call site that slips back to a framework picker (which
// paints "Select date", "Cancel", "OK") turns this red.

import 'dart:io';

import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:diet_guard_app/widgets/body/dated_value_card.dart';
import 'package:diet_guard_app/widgets/body/profile_card.dart';
import 'package:diet_guard_app/widgets/history/history_filter.dart';
import 'package:diet_guard_app/widgets/history/history_filter_sheet.dart';
import 'package:diet_guard_app/widgets/meal_time_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../label_finders.dart';
import '../no_words_support.dart';
import '../screens/body_screen_support.dart';

Future<void> _host(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

/// Opens the picker behind [control] and asserts the open dialog paints at
/// least [minStrings] strings, none of them a word, and no tooltip.
Future<void> _expectWordless(
  WidgetTester tester,
  Finder control, {
  required int minStrings,
  required String where,
}) async {
  await tester.tap(control);
  await tester.pumpAndSettle();
  expect(find.byType(Dialog), findsOneWidget, reason: '$where: no dialog');
  expectNoWords(tester, minStrings: minStrings, where: where);
  expect(
    find.descendant(of: find.byType(Dialog), matching: find.byType(Tooltip)),
    findsNothing,
    reason: '$where: a tooltip paints its words on long-press',
  );
}

FilterSheet _sheet(DateTimeRange? range) => FilterSheet(
  filter: HistoryFilter(dateRange: range),
  sortField: HistorySortField.date,
  ascending: false,
  maxKcal: 1000,
  maxProtein: 100,
  maxCarbs: 100,
  maxFat: 100,
  onFilterChanged: (_) {},
  onSortChanged: ({required field, required asc}) {},
  onApply: () {},
  onClear: () {},
);

void main() {
  testWidgets('meal-time exact picker', (tester) async {
    await _host(
      tester,
      MealTimeDropdown(
        icon: Icons.wb_sunny,
        semanticLabel: 'First meal',
        value: 480,
        minMinute: 0,
        maxMinute: 1424,
        onChanged: (_) {},
      ),
    );
    await _expectWordless(
      tester,
      byIconLabel('Type or pick an exact time'),
      minStrings: 2,
      where: 'time',
    );
  });

  for (final range in [
    null,
    DateTimeRange(start: DateTime(2026, 3, 2), end: DateTime(2026, 3, 9)),
  ]) {
    testWidgets('history date-range picker (preset: ${range != null})', (
      tester,
    ) async {
      await _host(tester, _sheet(range));
      await _expectWordless(
        tester,
        find.byIcon(Icons.date_range),
        minStrings: 28,
        where: 'range',
      );
    });
  }

  testWidgets('body dated-value day picker', (tester) async {
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
    await _expectWordless(
      tester,
      find.byIcon(Icons.event),
      minStrings: 28,
      where: 'dated value',
    );
  });

  testWidgets('profile birth-date picker', (tester) async {
    final store = MemoryDocStore();
    await setUpBodyServices(store);
    addTearDown(tearDownBodyServices);
    await _host(tester, ProfileCard(onSaved: () {}));
    await _expectWordless(
      tester,
      byIconLabel('Birth date'),
      minStrings: 12,
      where: 'birth',
    );
  });

  group('log meal', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('dg_pickers_');
      LogStorageService.resetForTesting(store: FileDocumentStore(dir));
      FoodBankService.resetForTesting(store: FileDocumentStore(dir));
      AppSettingsService.resetForTesting(store: FileDocumentStore(dir));
      BudgetHistoryService.resetForTesting(store: FileDocumentStore(dir));
      await MealScheduleService.initForTesting(FileDocumentStore(dir));
    });
    tearDown(() async {
      LogStorageService.resetForTesting();
      FoodBankService.resetForTesting();
      AppSettingsService.resetForTesting();
      BudgetHistoryService.resetForTesting();
      MealScheduleService.resetForTesting();
      await dir.delete(recursive: true);
    });
    _logLater();
  });
}

void _logLater() {
  testWidgets('log-for-later date picker', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });
    await _expectWordless(
      tester,
      controlByLabel('Log for later'),
      minStrings: 28,
      where: 'log later',
    );
  });
}
