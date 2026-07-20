import 'dart:io';

import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/screens/calendar_screen.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _label(DateTime d) => '${_monthNames[d.month - 1]} ${d.year}';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_calendar_');
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
    await AppSettingsService.initForTesting(FileDocumentStore(tempDir));
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    AppSettingsService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: CalendarScreen()));
    await tester.pumpAndSettle();
  }

  /// `FilledButton.onPressed` only accepts a synchronous `VoidCallback`, so
  /// `_onEditOrSaveBudget`'s real dart:io write is fired-and-forgotten by
  /// `tester.tap()` -- `pumpAndSettle()` alone can return before it
  /// resolves. Poll for the observable effect instead, mirroring
  /// settings_screen_test.dart's `pumpUntil` for the same class of issue.
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

  testWidgets('shows the default 2200 kcal budget, read-only, with an Edit '
      'button', (tester) async {
    await pumpScreen(tester);
    expect(find.widgetWithText(TextField, '2200'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Edit'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
  });

  testWidgets('tapping Edit unlocks the field and relabels the button Save', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Edit'));
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isTrue);
  });

  testWidgets('entering an invalid value keeps editing open with an error', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Edit'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(find.text('Enter a whole number of kcal.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
  });

  testWidgets('a zero value is rejected and editing stays open', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Edit'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(find.text('Budget must be a positive number.'), findsOneWidget);
  });

  testWidgets('saving a valid value persists it and reverts to read-only', (
    tester,
  ) async {
    // Real dart:io writes (AppSettingsService._persist, LogStorageService's
    // subsequent re-read) complete on the real event loop, not a microtask
    // pumpAndSettle alone drains -- runAsync interleaves real waits with
    // frame pumps, mirroring settings_screen_test.dart's device-flow tests.
    await tester.runAsync(() async {
      await pumpScreen(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Edit'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '1800');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await pumpUntil(tester, () => find.text('Saved.').evaluate().isNotEmpty);

      expect(find.text('Saved.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Edit'), findsOneWidget);
      expect(AppSettingsService.dailyKcalGoal, 1800);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.enabled, isFalse);
    });
  });

  testWidgets('shows streak and year-to-date summary text', (tester) async {
    await pumpScreen(tester);
    expect(find.textContaining('Logging streak:'), findsOneWidget);
    expect(find.textContaining('This year:'), findsOneWidget);
  });

  testWidgets('month navigation steps the displayed month back and forward', (
    tester,
  ) async {
    await pumpScreen(tester);
    final now = DateTime.now();
    expect(find.text(_label(now)), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pump();
    expect(
      find.text(_label(DateTime(now.year, now.month - 1))),
      findsOneWidget,
    );

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    expect(find.text(_label(now)), findsOneWidget);
  });

  testWidgets('tapping a day navigates to HistoryScreen filtered to that day', (
    tester,
  ) async {
    await pumpScreen(tester);
    final today = DateTime.now();
    await tester.tap(find.text('${today.day}'));
    await tester.pumpAndSettle();

    expect(find.byType(HistoryScreen), findsOneWidget);
    final screen = tester.widget<HistoryScreen>(find.byType(HistoryScreen));
    final range = screen.initialDateRange!;
    expect(range.start.year, today.year);
    expect(range.start.month, today.month);
    expect(range.start.day, today.day);
    expect(range.end, range.start);
  });
}
